----------------------------------------------------------------------------------
-- Engineer: Halil Ibrahim Ayan
-- Design Name: BME280 Controller
-- Module Name: bme280_controller - Behavioral
-- Project Name: Designed for FPGA-based environmental sensing via SPI.
-- Tool Versions: v1.0
-- Description:
--   Fully synchronous BME280 sensor controller that handles:
--     * Hardware initialisation over SPI (humidity, pressure/temperature config)
--     * One-shot calibration readout from sensor NVM:
--         calib[0..23]  <- 0x88-0x9F  (dig_T1..dig_P9, 24 bytes)
--         calib[24]     <- 0xA1       (dig_H1,          1 byte )
--         calib[25..31] <- 0xE1-0xE7  (dig_H2..dig_H6,  7 bytes)
--     * Periodic burst ADC readout (pressure, temperature, humidity)
--     * Configurable measurement wait period via generic g_meas_wait
--
--   State machine sequence:
--     ST_INIT -> ST_CAL1_READ -> ST_CAL2_READ -> ST_CAL3_READ -> ST_CAL_DONE
--     -> ST_IDLE -> ST_WAIT_MEAS -> ST_BURST_READ -> ST_PROCESS_DATA -> ST_DONE
--     (ST_IDLE..ST_DONE loop indefinitely)
--
--   Outputs:
--     calib_data_o  : 256-bit flat vector, calib[0] in bits 255:248 (MSB-first)
--     calib_valid_o : pulses HIGH for one clock cycle when calibration is ready
--     temp_data_o   : 20-bit raw ADC temperature value
--     press_data_o  : 20-bit raw ADC pressure value
--     hum_data_o    : 16-bit raw ADC humidity value
--     data_valid_o  : pulses HIGH for one clock cycle when ADC data is ready
-- Revision 0.01
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity bme280_controller is
    generic (
        g_meas_wait : integer := 1_000_000
    );
    port (
        clk_i           : in  std_logic;
        rst_i           : in  std_logic;

        spi_done_i      : in  std_logic;
        spi_start_o     : out std_logic;
        spi_cs_o        : out std_logic;
        rx_data_i       : in  std_logic_vector(7 downto 0);
        tx_data_o       : out std_logic_vector(7 downto 0);

        -- Raw ADC outputs
        temp_data_o     : out std_logic_vector(19 downto 0);
        press_data_o    : out std_logic_vector(19 downto 0);
        hum_data_o      : out std_logic_vector(15 downto 0);
        data_valid_o    : out std_logic;

        -- Calibration outputs
        -- 32 bytes packed MSB-first:
        --   bits 255:248 = calib[0]  (dig_T1 LSB, reg 0x88)
        --   ...
        --   bits   7:0   = calib[31] (dig_H6,     reg 0xE7)
        calib_data_o    : out std_logic_vector(255 downto 0);
        calib_valid_o   : out std_logic
    );
end entity;

architecture Behavioral of bme280_controller is

    -- -------------------------------------------------------------------------
    -- State machine
    -- -------------------------------------------------------------------------
    type States is (
        ST_INIT,
        ST_CAL1_READ,
        ST_CAL2_READ,
        ST_CAL3_READ,
        ST_CAL_DONE,
        ST_IDLE,
        ST_WAIT_MEAS,
        ST_BURST_READ,
        ST_PROCESS_DATA,
        ST_DONE
    );
    signal state : States := ST_INIT;

    -- -------------------------------------------------------------------------
    -- Calibration storage  (32 bytes)
    -- -------------------------------------------------------------------------
    type calib_array_t is array(0 to 31) of std_logic_vector(7 downto 0);
    signal calib_s : calib_array_t := (others => (others => '0'));

    -- -------------------------------------------------------------------------
    -- ADC byte registers
    -- -------------------------------------------------------------------------
    signal press_msb_s  : std_logic_vector(7 downto 0) := (others => '0');
    signal press_lsb_s  : std_logic_vector(7 downto 0) := (others => '0');
    signal press_xlsb_s : std_logic_vector(7 downto 0) := (others => '0');
    signal temp_msb_s   : std_logic_vector(7 downto 0) := (others => '0');
    signal temp_lsb_s   : std_logic_vector(7 downto 0) := (others => '0');
    signal temp_xlsb_s  : std_logic_vector(7 downto 0) := (others => '0');
    signal hum_msb_s    : std_logic_vector(7 downto 0) := (others => '0');
    signal hum_lsb_s    : std_logic_vector(7 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- SPI control
    -- -------------------------------------------------------------------------
    signal byte_index    : integer range 0 to 31        := 0;
    signal spi_start_s   : std_logic                    := '0';
    signal spi_cs_s    	 : std_logic                    := '1';
    signal tx_data_s     : std_logic_vector(7 downto 0) := (others => '0');
    signal wait_counter  : integer range 0 to 1_100_000 := 0;

    constant SPI_START_HOLD : integer := 15;
    signal spi_start_cnt : integer range 0 to SPI_START_HOLD := 0;

begin

    spi_start_o <= spi_start_s;
    spi_cs_o    <= spi_cs_s;
    tx_data_o   <= tx_data_s;

    -- Pack calibration array into the flat output port
    GEN_CALIB_OUT : for i in 0 to 31 generate
        calib_data_o(255 - i*8 downto 248 - i*8) <= calib_s(i);
    end generate;

    -- =========================================================================
    MAIN: process(clk_i, rst_i)
    begin
        if rst_i = '1' then
            state         <= ST_INIT;
            byte_index    <= 0;
            wait_counter  <= 0;
            spi_start_s   <= '0';
            spi_start_cnt <= 0;
            spi_cs_s      <= '1';
            tx_data_s     <= (others => '0');
            data_valid_o  <= '0';
            calib_valid_o <= '0';
            press_msb_s   <= (others => '0');
            press_lsb_s   <= (others => '0');
            press_xlsb_s  <= (others => '0');
            temp_msb_s    <= (others => '0');
            temp_lsb_s    <= (others => '0');
            temp_xlsb_s   <= (others => '0');
            hum_msb_s     <= (others => '0');
            hum_lsb_s     <= (others => '0');
            calib_s       <= (others => (others => '0'));

        elsif rising_edge(clk_i) then

            calib_valid_o <= '0';

            if spi_start_cnt > 0 then
                spi_start_s   <= '1';
                spi_start_cnt <= spi_start_cnt - 1;
            else
                spi_start_s <= '0';
            end if;

            case state is

                -- =============================================================
                -- ST_INIT
                -- =============================================================
                when ST_INIT =>
                    case byte_index is
                        when 0 =>
                            spi_cs_s      <= '0';
                            tx_data_s     <= x"72";
                            spi_start_cnt <= SPI_START_HOLD;
                            byte_index    <= 1;
                        when 1 =>
                            if spi_done_i = '1' then
                                tx_data_s     <= x"01";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 2;
                            end if;
                        when 2 =>
                            if spi_done_i = '1' then
                                spi_cs_s   <= '1';
                                byte_index <= 3;
                            end if;
                        when 3 =>
                            spi_cs_s      <= '0';
                            tx_data_s     <= x"74";
                            spi_start_cnt <= SPI_START_HOLD;
                            byte_index    <= 4;
                        when 4 =>
                            if spi_done_i = '1' then
                                tx_data_s     <= x"27";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 5;
                            end if;
                        when 5 =>
                            if spi_done_i = '1' then
                                spi_cs_s     <= '1';
                                byte_index   <= 0;
                                state        <= ST_CAL1_READ;
                            end if;
                        when others =>
                            spi_cs_s   <= '1';
                            byte_index <= 0;
                    end case;

                -- =============================================================
                -- ST_CAL1_READ
                -- Burst read 0x88-0x9F -> calib_s[0..23]  (24 bytes)
                --
                -- byte_index  tx_data_s  action
                -- ----------  ---------  ----------------------------
                --     0       0x88       assert CS, send addr, start
                --     1       0x00       addr done, flush byte, start
                --     2..24   0x00       capture calib[idx-2], send dummy, start
                --     25      (wait)     capture calib[23], deassert CS -> ST_CAL2_READ
                -- =============================================================
                when ST_CAL1_READ =>
                    case byte_index is
                        when 0 =>
                            spi_cs_s      <= '0';
                            tx_data_s     <= x"88";
                            spi_start_cnt <= SPI_START_HOLD;
                            byte_index    <= 1;
                        when 1 =>
                            if spi_done_i = '1' then
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 2;
                            end if;
                        when 25 =>
                            if spi_done_i = '1' then
                                calib_s(23) <= rx_data_i;
                                spi_cs_s    <= '1';
                                byte_index  <= 0;
                                state       <= ST_CAL2_READ;
                            end if;
                        when others =>   -- byte_index 2..24
                            if spi_done_i = '1' then
                                calib_s(byte_index - 2) <= rx_data_i;
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= byte_index + 1;
                            end if;
                    end case;

                -- =============================================================
                -- ST_CAL2_READ
                -- Single read 0xA1 -> calib_s[24]  (dig_H1, 1 byte)
                --
                -- byte_index  tx_data_s  action
                --     0       0xA1       assert CS, send addr, start
                --     1       0x00       flush
                --     2       (wait)     capture calib[24], deassert CS -> ST_CAL3_READ
                -- =============================================================
                when ST_CAL2_READ =>
                    case byte_index is
                        when 0 =>
                            spi_cs_s      <= '0';
                            tx_data_s     <= x"A1";
                            spi_start_cnt <= SPI_START_HOLD;
                            byte_index    <= 1;
                        when 1 =>
                            if spi_done_i = '1' then
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 2;
                            end if;
                        when 2 =>
                            if spi_done_i = '1' then
                                calib_s(24) <= rx_data_i;
                                spi_cs_s    <= '1';
                                byte_index  <= 0;
                                state       <= ST_CAL3_READ;
                            end if;
                        when others =>
                            spi_cs_s   <= '1';
                            byte_index <= 0;
                    end case;

                -- =============================================================
                -- ST_CAL3_READ
                -- Burst read 0xE1-0xE7 -> calib_s[25..31]  (7 bytes, dig_H2-H6)
                --
                -- byte_index  tx_data_s  action
                --     0       0xE1       assert CS, send addr, start
                --     1       0x00       flush
                --     2..7    0x00       capture calib[idx-2+25], send dummy, start
                --     8       (wait)     capture calib[31], deassert CS -> ST_CAL_DONE
                -- =============================================================
                when ST_CAL3_READ =>
                    case byte_index is
                        when 0 =>
                            spi_cs_s      <= '0';
                            tx_data_s     <= x"E1";
                            spi_start_cnt <= SPI_START_HOLD;
                            byte_index    <= 1;
                        when 1 =>
                            if spi_done_i = '1' then
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 2;
                            end if;
                        when 8 =>
                            if spi_done_i = '1' then
                                calib_s(31) <= rx_data_i;
                                spi_cs_s    <= '1';
                                byte_index  <= 0;
                                state       <= ST_CAL_DONE;
                            end if;
                        when others =>   -- byte_index 2..7
                            if spi_done_i = '1' then
                                calib_s(byte_index - 2 + 25) <= rx_data_i;
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= byte_index + 1;
                            end if;
                    end case;

                -- =============================================================
                -- ST_CAL_DONE  - single-cycle pulse on calib_valid_o
                -- =============================================================
                when ST_CAL_DONE =>
                    calib_valid_o <= '1';
                    state         <= ST_IDLE;

                -- =============================================================
                -- ST_IDLE
                -- =============================================================
                when ST_IDLE =>
                    data_valid_o <= '0';
                    state        <= ST_WAIT_MEAS;

                -- =============================================================
                -- ST_WAIT_MEAS
                -- =============================================================
                when ST_WAIT_MEAS =>
                    if wait_counter >= g_meas_wait then
                        wait_counter <= 0;
                        state        <= ST_BURST_READ;
                    else
                        wait_counter <= wait_counter + 1;
                    end if;

                -- =============================================================
                -- ST_BURST_READ
                -- =============================================================
                when ST_BURST_READ =>
                    case byte_index is
                        when 0 =>
                            spi_cs_s      <= '0';
                            tx_data_s     <= x"F7";
                            spi_start_cnt <= SPI_START_HOLD;
                            byte_index    <= 1;
                        when 1 =>
                            if spi_done_i = '1' then
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 2;
                            end if;
                        when 2 =>
                            if spi_done_i = '1' then
                                press_msb_s   <= rx_data_i;
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 3;
                            end if;
                        when 3 =>
                            if spi_done_i = '1' then
                                press_lsb_s   <= rx_data_i;
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 4;
                            end if;
                        when 4 =>
                            if spi_done_i = '1' then
                                press_xlsb_s  <= rx_data_i;
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 5;
                            end if;
                        when 5 =>
                            if spi_done_i = '1' then
                                temp_msb_s    <= rx_data_i;
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 6;
                            end if;
                        when 6 =>
                            if spi_done_i = '1' then
                                temp_lsb_s    <= rx_data_i;
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 7;
                            end if;
                        when 7 =>
                            if spi_done_i = '1' then
                                temp_xlsb_s   <= rx_data_i;
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 8;
                            end if;
                        when 8 =>
                            if spi_done_i = '1' then
                                hum_msb_s     <= rx_data_i;
                                tx_data_s     <= x"00";
                                spi_start_cnt <= SPI_START_HOLD;
                                byte_index    <= 9;
                            end if;
                        when 9 =>
                            if spi_done_i = '1' then
                                hum_lsb_s  <= rx_data_i;
                                spi_cs_s   <= '1';
                                byte_index <= 0;
                                state      <= ST_PROCESS_DATA;
                            end if;
                        when others =>
                            spi_cs_s   <= '1';
                            byte_index <= 0;
                    end case;

                -- =============================================================
                -- ST_PROCESS_DATA
                -- =============================================================
                when ST_PROCESS_DATA =>
                    temp_data_o  <= temp_msb_s  & temp_lsb_s  & temp_xlsb_s(7 downto 4);
                    press_data_o <= press_msb_s & press_lsb_s & press_xlsb_s(7 downto 4);
                    hum_data_o   <= hum_msb_s   & hum_lsb_s;
                    state        <= ST_DONE;

                -- =============================================================
                -- ST_DONE
                -- =============================================================
                when ST_DONE =>
                    data_valid_o <= '1';
                    state        <= ST_IDLE;

            end case;
        end if;
    end process;

end Behavioral;