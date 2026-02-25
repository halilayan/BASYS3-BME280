----------------------------------------------------------------------------------
-- Engineer: Halil Ibrahim Ayan
-- Design Name: SPI Master
-- Module Name: spi_master - Behavioral
-- Project Name: Designed for generic FPGA-based SPI communication.
-- Tool Versions: v1.0
-- Description: 
-- 	Fully synchronous SPI Master controller with configurable:
-- 	  * System clock and SPI clock frequency
-- 	  * CPOL and CPHA (SPI Modes 0-3)
--			SPI Mode 0 => cpol_g = 0 & cpha_g = 0
--			SPI Mode 1 => cpol_g = 0 & cpha_g = 1
--			SPI Mode 2 => cpol_g = 1 & cpha_g = 0
--			SPI Mode 3 => cpol_g = 1 & cpha_g = 1
-- 	  * Data width (generic)
-- Revision 0.02 
-- 
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;


entity spi_master is
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
        data_i       : in  std_logic_vector((data_bit_g - 1) downto 0);
        data_o       : out std_logic_vector((data_bit_g - 1) downto 0);
        data_ready_o : out std_logic;

        miso_i       : in  std_logic;
        sclk_o       : out std_logic;
        mosi_o       : out std_logic;
        cs_o         : out std_logic
    );
end entity;

architecture Behavioral of spi_master is

    constant sclk_half_c : integer := clkfreq_g / (sclkfreq_g * 2);

    signal edge_cntr_s   : integer range 0 to sclk_half_c := 0;
    signal sclk_int_s    : std_logic := '0';
    signal sclk_en_s     : std_logic := '0';

    type States is (ST_IDLE, ST_TX_RX, ST_END);
    signal state : States := ST_IDLE;

    signal sclk_idle_s     : std_logic;
    signal sclk_reg_s      : std_logic;
    signal sclk_prev_reg_s : std_logic;

    signal leading_s       : std_logic;
    signal trailing_s      : std_logic;

    signal data_tx_s       : std_logic_vector((data_bit_g - 1) downto 0);
    signal data_rx_s       : std_logic_vector((data_bit_g - 1) downto 0);

    signal counter_s       : integer range 0 to data_bit_g - 1 := 0;

begin

    sclk_idle_s <= '0' when cpol_g = '0' else '1';

    -- =========================================================================
    -- P_SCLK_GEN
    -- =========================================================================
    P_SCLK_GEN : process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                sclk_int_s  <= sclk_idle_s;
                edge_cntr_s <= 0;
            elsif sclk_en_s = '1' then
                if edge_cntr_s = sclk_half_c - 1 then
                    sclk_int_s  <= not sclk_int_s;
                    edge_cntr_s <= 0;
                else
                    edge_cntr_s <= edge_cntr_s + 1;
                end if;
            else
                sclk_int_s  <= sclk_idle_s;
                edge_cntr_s <= 0;
            end if;
        end if;
    end process P_SCLK_GEN;

    -- =========================================================================
    -- SCLK_GATE
    -- =========================================================================
    SCLK_GATE : process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                sclk_reg_s <= sclk_idle_s;
            elsif sclk_en_s = '1' then
                sclk_reg_s <= sclk_int_s;
            else
                sclk_reg_s <= sclk_idle_s;
            end if;
        end if;
    end process SCLK_GATE;

    sclk_o <= sclk_reg_s;

    -- =========================================================================
    -- EDGE_DETECT
    -- =========================================================================
    EDGE_DETECT : process(clk_i)
    begin
        if rising_edge(clk_i) then
            leading_s       <= '0';
            trailing_s      <= '0';
            sclk_prev_reg_s <= sclk_reg_s;

            if sclk_prev_reg_s = '0' and sclk_reg_s = '1' then
                if cpha_g = '0' then
                    leading_s  <= '1';
                else
                    trailing_s <= '1';
                end if;
            elsif sclk_prev_reg_s = '1' and sclk_reg_s = '0' then
                if cpha_g = '0' then
                    trailing_s <= '1';
                else
                    leading_s  <= '1';
                end if;
            end if;
        end if;
    end process EDGE_DETECT;

    -- =========================================================================
    -- MAIN
    -- =========================================================================
    MAIN : process(clk_i, rst_i)
    begin
        if rst_i = '1' then
            data_ready_o <= '0';
            counter_s      	<= 0;
            data_tx_s      	<= (others => '0');
            data_rx_s      	<= (others => '0');
            cs_o         	<= '1';
            mosi_o       	<= '0';
            sclk_en_s      	<= '0';
            state        	<= ST_IDLE;

        elsif rising_edge(clk_i) then
            case state is

                when ST_IDLE =>
                    data_ready_o	<= '0';
                    cs_o         	<= '1';
                    sclk_en_s      	<= '0';
                    counter_s      	<= 0;

                    if cpha_g = '0' then
                        mosi_o <= data_i(data_bit_g - 1);
                    else
                        mosi_o <= '0';
                    end if;

                    if tx_en_i = '1' then
                        cs_o    	<= '0';
                        data_tx_s 	<= data_i;
                        sclk_en_s 	<= '1';
                        state   	<= ST_TX_RX;
                    end if;

                when ST_TX_RX =>
                    cs_o <= '0';

                    if cpha_g = '0' then
                        if leading_s = '1' then
                            data_rx_s(data_bit_g - 1 downto 1) 	<= data_rx_s(data_bit_g - 2 downto 0);
                            data_rx_s(0) 						<= miso_i;

                            if counter_s = data_bit_g - 1 then
                                state <= ST_END;
                            else
                                counter_s <= counter_s + 1;
                            end if;
                        end if;

                        if trailing_s = '1' then
                            data_tx_s 	<= data_tx_s(data_bit_g - 2 downto 0) & '0';
                            mosi_o  	<= data_tx_s(data_bit_g - 2);
                        end if;

                    else
                        if leading_s = '1' then
                            mosi_o  	<= data_tx_s(data_bit_g - 1);
                            data_tx_s 	<= data_tx_s(data_bit_g - 2 downto 0) & '0';
                        end if;

                        if trailing_s = '1' then
                            data_rx_s(data_bit_g - 1 downto 1) 	<= data_rx_s(data_bit_g - 2 downto 0);
                            data_rx_s(0) 						<= miso_i;

                            if counter_s = data_bit_g - 1 then
                                state <= ST_END;
                            else
                                counter_s <= counter_s + 1;
                            end if;
                        end if;
                    end if;

                when ST_END =>
                    data_ready_o <= '1';
                    data_o       <= data_rx_s;
                    sclk_en_s    <= '0';
                    cs_o         <= '1';
                    state        <= ST_IDLE;

            end case;
        end if;
    end process MAIN;

end Behavioral;