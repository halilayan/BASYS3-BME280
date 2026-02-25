library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity top_level is
    port (
        clk_i      : in  std_logic;
        rst_i      : in  std_logic;
        spi_cs_o   : out std_logic;
        spi_sclk_o : out std_logic;
        spi_mosi_o : out std_logic;
        spi_miso_i : in  std_logic;
        uart_tx_o  : out std_logic
    );
end entity;

architecture Behavioral of top_level is

    -- =========================================================================
    -- Component Declarations
    -- =========================================================================

    component bme280_controller is
        port (
            clk_i         : in  std_logic;
            rst_i         : in  std_logic;
            spi_done_i    : in  std_logic;
            spi_start_o   : out std_logic;
            spi_cs_o      : out std_logic;
            rx_data_i     : in  std_logic_vector(7 downto 0);
            tx_data_o     : out std_logic_vector(7 downto 0);
            temp_data_o   : out std_logic_vector(19 downto 0);
            press_data_o  : out std_logic_vector(19 downto 0);
            hum_data_o    : out std_logic_vector(15 downto 0);
            data_valid_o  : out std_logic;
            calib_data_o  : out std_logic_vector(255 downto 0);
            calib_valid_o : out std_logic
        );
    end component;

    component spi_master is
        generic (
            clkfreq_g  : integer   := 100_000_000;
            sclkfreq_g : integer   := 10_000_000;
            cpol_g     : std_logic := '0';
            cpha_g     : std_logic := '0';
            data_bit_g : integer   := 8
        );
        port (
            clk_i        : in  std_logic;
            rst_i        : in  std_logic;
            tx_en_i      : in  std_logic;
            data_i       : in  std_logic_vector(7 downto 0);
            data_o       : out std_logic_vector(7 downto 0);
            data_ready_o : out std_logic;
            miso_i       : in  std_logic;
            sclk_o       : out std_logic;
            mosi_o       : out std_logic;
            cs_o         : out std_logic
        );
    end component;

    component uart_tx is
        port (
            clk         : in  std_logic;
            tx_start    : in  std_logic;
            data_in     : in  std_logic_vector(7 downto 0);
            tx_data_out : out std_logic;
            tx_done     : out std_logic;
            tx_busy     : out std_logic
        );
    end component;

    -- =========================================================================
    -- Internal Signals
    -- =========================================================================

    signal spi_start_s   : std_logic;
    signal spi_done_s    : std_logic;
    signal spi_mosi_s    : std_logic_vector(7 downto 0);
    signal spi_miso_s    : std_logic_vector(7 downto 0);
    signal spi_cs_unused : std_logic;

    signal temp_data_s   : std_logic_vector(19 downto 0);
    signal press_data_s  : std_logic_vector(19 downto 0);
    signal hum_data_s    : std_logic_vector(15 downto 0);
    signal data_valid_s  : std_logic;

    signal calib_data_s  : std_logic_vector(255 downto 0);
    signal calib_valid_s : std_logic;

    signal uart_start_s  : std_logic := '0';
    signal uart_data_s   : std_logic_vector(7 downto 0) := (others => '0');
    signal uart_done_s   : std_logic;
    signal uart_busy_s   : std_logic;

    type UartStates is (U_CAL, U_IDLE, U_LOAD, U_WAIT);
    signal uart_state    : UartStates := U_CAL;
    signal byte_sel      : integer range 0 to 32 := 0;

    signal calib_lat_s   : std_logic_vector(255 downto 0) := (others => '0');
    signal temp_lat_s    : std_logic_vector(19 downto 0)  := (others => '0');
    signal press_lat_s   : std_logic_vector(19 downto 0)  := (others => '0');
    signal hum_lat_s     : std_logic_vector(15 downto 0)  := (others => '0');

    signal cal_sent_s    : std_logic := '0';

    constant TX_RATE_LIMIT : integer := 50_000_000;
    signal tx_rate_cnt   : integer range 0 to TX_RATE_LIMIT := 0;

begin

    -- =========================================================================
    -- Instantiations
    -- =========================================================================

    U_BME280 : bme280_controller
        port map (
            clk_i         => clk_i,
            rst_i         => rst_i,
            spi_done_i    => spi_done_s,
            spi_start_o   => spi_start_s,
            spi_cs_o      => spi_cs_o,
            rx_data_i     => spi_miso_s,
            tx_data_o     => spi_mosi_s,
            temp_data_o   => temp_data_s,
            press_data_o  => press_data_s,
            hum_data_o    => hum_data_s,
            data_valid_o  => data_valid_s,
            calib_data_o  => calib_data_s,
            calib_valid_o => calib_valid_s
        );

    U_SPI : spi_master
        generic map (
            clkfreq_g   => 100_000_000,
            sclkfreq_g  => 10_000_000,
            cpol_g      => '0',
            cpha_g      => '0',
            data_bit_g  => 8
        )
        port map (
            clk_i        => clk_i,
            rst_i        => rst_i,
            tx_en_i      => spi_start_s,
            data_i       => spi_mosi_s,
            data_o       => spi_miso_s,
            data_ready_o => spi_done_s,
            miso_i       => spi_miso_i,
            sclk_o       => spi_sclk_o,
            mosi_o       => spi_mosi_o,
            cs_o         => spi_cs_unused
        );

    U_UART : uart_tx
        port map (
            clk         => clk_i,
            tx_start    => uart_start_s,
            data_in     => uart_data_s,
            tx_data_out => uart_tx_o,
            tx_done     => uart_done_s,
            tx_busy     => uart_busy_s
        );

    -- =========================================================================
    -- UART Sequencer Process
    -- =========================================================================
    P_UART_SEQ : process(clk_i,rst_i)
        variable calib_byte_idx : integer;
    begin
	
        if rst_i = '1' then
            uart_state  <= U_CAL;
            byte_sel    <= 0;
            cal_sent_s  <= '0';
            calib_lat_s <= (others => '0');
            temp_lat_s  <= (others => '0');
            press_lat_s <= (others => '0');
            hum_lat_s   <= (others => '0');
            uart_data_s <= (others => '0');
            tx_rate_cnt <= 0;            		
	
        elsif rising_edge(clk_i) then
            uart_start_s <= '0';
			
			if tx_rate_cnt < TX_RATE_LIMIT then
				tx_rate_cnt <= tx_rate_cnt + 1;
			end if;

			case uart_state is

				when U_CAL =>
					if calib_valid_s = '1' and cal_sent_s = '0' then
						calib_lat_s <= calib_data_s;
						byte_sel    <= 0;
						uart_state  <= U_LOAD;
					end if;

				when U_IDLE =>
					if data_valid_s = '1' and tx_rate_cnt = TX_RATE_LIMIT then
						temp_lat_s  <= temp_data_s;
						press_lat_s <= press_data_s;
						hum_lat_s   <= hum_data_s;
						byte_sel    <= 0;
						tx_rate_cnt <= 0;
						uart_state  <= U_LOAD;
					end if;

				when U_LOAD =>
					if cal_sent_s = '0' then
						if byte_sel = 0 then
							uart_data_s <= x"FE";
						else
							calib_byte_idx := byte_sel - 1;
							uart_data_s <=	calib_lat_s(255 - calib_byte_idx * 8 downto	248 - calib_byte_idx * 8);
						end if;
					else
						case byte_sel is
							when 0 => uart_data_s <= x"FF";
							when 1 => uart_data_s <= temp_lat_s(19 downto 12);
							when 2 => uart_data_s <= temp_lat_s(11 downto 4);
							when 3 => uart_data_s <= temp_lat_s(3 downto 0) & "0000";
							when 4 => uart_data_s <= press_lat_s(19 downto 12);
							when 5 => uart_data_s <= press_lat_s(11 downto 4);
							when 6 => uart_data_s <= press_lat_s(3 downto 0) & "0000";
							when 7 => uart_data_s <= hum_lat_s(15 downto 8);
							when 8 => uart_data_s <= hum_lat_s(7 downto 0);
							when others => uart_data_s <= x"00";
						end case;
					end if;
					uart_start_s <= '1';
					uart_state   <= U_WAIT;

				when U_WAIT =>
					if uart_done_s = '1' then
						if cal_sent_s = '0' then
							if byte_sel = 32 then
								cal_sent_s   <= '1';
								uart_state <= U_IDLE;
							else
								byte_sel   <= byte_sel + 1;
								uart_state <= U_LOAD;
							end if;
						else
							if byte_sel = 8 then
								uart_state <= U_IDLE;
							else
								byte_sel   <= byte_sel + 1;
								uart_state <= U_LOAD;
							end if;
						end if;
					end if;
			end case;
        end if;
    end process;

end Behavioral;