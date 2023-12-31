library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

--
-- SoC for HD63C09 SBC II Testboard
--
-- Tom LeMense
--
-- PH1 minimal testboard setup
-- clock generation and CPU execution
--
-- 1x M9K "RAM" at $0000...$03FF
-- 1x M9K "ROM" at $FC00...$FFFF
-- address decoder
-- clock generator
-- LED4 control at $E000
-- PB1 status at $E001
-- SEVEN SEG display at $E002
--
-- Target = Altera 10M08 CPLD on QMTECH MAX10 board
-- Tool = Quartus 
--
-- (versions "1.x" are all for HD63C09 SBC I)
-- VERSION 2.0 - April 23, 2021
--
-- 

entity HD6309_ph0_top is port (
   sys_clk : in std_logic;          -- 50 MHz master oscillator on MAINBOARD
   key_1 : in std_logic;            -- SW #1 on MAINBOARD ("warm reset")
   sys_rst_n : in std_logic;        -- SW #2 on MAINBOARD ("cold reset")
   led_1 : out std_logic;           -- LED #1 on MAINBOARD ("cold reset")
   led_2 : out std_logic;           -- LED #2 on MAINBOARD ("warm reset")
   uart_rx : in std_logic;          -- serial data output from MAINBOARD USB bridge
   uart_tx : out std_logic;         -- serial data input into MAINBOARD USB bridge
   dig_1 : out std_logic;           -- 7 segment LED digit #1 drive ('1' = driven)
   dig_2 : out std_logic;           -- 7 segment LED digit #2 drive ('1' = driven)   
   dig_3 : out std_logic;           -- 7 segment LED digit #3 drive ('1' = driven)   
   seg_full : out std_logic_vector(7 downto 0);  -- DP, segments g-a ('0' = illuminate)
   
   t_lvrst_n : in std_logic;        -- RESET signal from RTC & Pushbutton
   t_rstreq : out std_logic;         -- RESET request to CPU

   t_eclk : out std_logic;          -- 3MHz 'E' clock to CPU
   t_qclk : out std_logic;          -- 3MHz 'Q' clock to CPU
   
   t_addr : inout std_logic_vector(15 downto 0);   -- CPU+SRAM address bus 
   t_maddr : out std_logic_vector(19 downto 11);   -- SRAM address bus
   t_data : inout std_logic_vector(7 downto 0);    -- CPU+SRAM data bus   
   t_aben_n : out std_logic;        -- CPU address bus buffer enable ('0' = connect to CPU)
   t_dben_n : out std_logic;        -- CPU data bus buffer enable ('0' = connect to CPU)
   t_dbdir : out std_logic;         -- CPU data bus buffer direction ('0' = CPU WRITE, '1' = CPU READ)
   
   t_ram_oe_n : out std_logic;      -- SRAM OEn control (active low)
   t_ram_cs_n : out std_logic;      -- SRAM CSn control (active low)
   t_ram_we_n : out std_logic;      -- SRAM WEn control (active low)
 
   t_ba : in std_logic;             -- CPU BA bus status signal
   t_bs : in std_logic;             -- CPU BS bus status signal
   t_lic : in std_logic;            -- CPU LIC status signal
   t_avma : in std_logic;           -- CPU AVMA status signal
   t_rw_n : in std_logic;           -- CPU R/~W status signal      
   t_halt_n : out std_logic;        -- CPU ~HALT control signal
   t_irq_n : out std_logic;         -- CPU ~IRQ control signal
   t_nmi_n : out std_logic;         -- CPU ~NMI control signal
   
   t_sci_rx : in std_logic;         -- SCI serial data output from USB bridge
   t_sci_tx : out std_logic;        -- SCI serial data input into USB bridge
   t_eci_rx : in std_logic;         -- ECI serial data output from USB bridge
   t_eci_tx : out std_logic;        -- ECI serial data input into USB bridge 
   t_eci_rts : in std_logic;        -- ECI Ready-To-Send output from USB bridge
   
   t_sda : inout std_logic;         -- I2C SDA bidirectional signal
   t_scl : out std_logic;           -- I2C SCL output signal
   
   t_ee_cs_n : out std_logic;       -- Boot image SPI EEPROM chip select
   t_ee_clk  : out std_logic;       -- SPI EEPROM CLK   
   t_ee_miso : in std_logic;        -- SPI EEPROM MISO
   t_ee_mosi : out std_logic;       -- SPI EEPROM MOSI

   t_sd_card : in std_logic;        -- SD Card presence detect ('0' = present)
   t_sd_cs_n : out std_logic;       -- SD Card SPI CS   
   t_sd_clk  : out std_logic;        -- SD Card SPI CLK
   t_sd_miso : in std_logic;        -- SD Card SPI MISO   
   t_sd_mosi : out std_logic;       -- SD Card SPI MOSI
   
   t_rgb_q : out std_logic;         -- 2x WS2812 RGB LED serial control output
   t_led_4 : out std_logic;         -- LED4 indicator ('0' = illuminate)
   t_led_busy : out std_logic;      -- BUSY LED indicator ('1' = illuminate)   
   t_conf_1 : in std_logic;         -- CONF1 jumper ('0' = shorted)
   t_conf_2 : in std_logic;         -- CONF2 jumper ('0' = shorted)
   t_btn : in std_logic             -- PUSHBUTTON input ('0' = pressed)
);
end HD6309_ph0_top;

architecture behavioral of HD6309_ph0_top is
   constant BIN_VERSION : std_logic_vector(7 downto 0) := "00100000";
   
   -- CPU and CPLD reset signals
   signal reset, warm_reset : std_logic;       -- cold and warm reset signals
	
   -- clock generation state and output drivers
   signal alat, clat : std_logic;              -- address and control latche enables
   signal busen, memwe, iowe : std_logic;      -- bus buffer and write enable signals
   
   -- latched CPU address and control signals
	signal addr_in : std_logic_vector(15 downto 0);
   signal addr : std_logic_vector(15 downto 0);  -- these are latched from CPU bus when 'alat'  
   signal ba, bs, rd, wr : std_logic;               --     is asserted by the clock generator
   signal lic, vma : std_logic;                     -- latched from CPU when 'clat' is asserted
	
   -- memory and peripheral select signals
   signal romsel, ramsel, iosel : std_logic;   -- rom, ram, and io area selects
   signal iportcs, oportcs : std_logic;        -- input and output port selects
	signal sevencs, sevenwr : std_logic;

   -- bidirectional datapaths for onchip peripherals
   signal data_in : std_logic_vector(7 downto 0);
   signal op_data_q, ip_data_q, seven_data_q : std_logic_vector(7 downto 0);
   
   -- bidirectional address bus for fpga "dma" access to SRAM
   signal addr_out : std_logic_vector(19 downto 0); -- address to drive to SRAM when accessing it
   signal sram_dma : std_logic;                     -- asserted when direct access to SRAM is required
   
   -- dynamic address translation
   signal dat_enable : std_logic;       -- DAT is enabled when '1'
	signal dat_page : std_logic_vector(7 downto 0);

   -------------------------------------
begin
	
   -- "cold" and "warm" reset generation
   warm_reset <= not key_1;             -- switch #1 on mainboard is "warm reset" CPU only
   led_1 <= not warm_reset;             -- led #1 on mainboard is "warm reset" indicator
   reset <= t_lvrst_n nand sys_rst_n;   -- "cold reset" is from RTC/PB input and switch #2 on MAINBOARD
   led_2 <= not reset;                  -- led #2 on mainboard is "cold reset" indicator
   t_rstreq <= reset or warm_reset;     -- reset CPU during both "cold" and "warm" resets
   
   -- map the CPU clock generator		
   clockgen0 : entity work.cpuclock port map (
      clk   => sys_clk,          -- 50 MHz system clock
      wait2 => '0',              -- pause clock generator at state 2 when high
      eclk  => t_eclk,           -- 3.125M E quadrature clock 
      qclk  => t_qclk,           -- 3.125M Q quadrature clock
      alat  => alat,             -- address bus latch enable
      clat  => clat,             -- control bus latch enable
      busen => busen,            -- data bus buffer enable (during memory or peripheral access)
      memwe  => memwe,           -- memory write enable
      iowe  => iowe              -- peripheral write enable
   );   

   -- latch the address and status signals when stable (ALAT strobe)
   process(sys_clk, alat, t_addr, t_ba, t_bs, t_rw_n)
   begin
      if rising_edge(sys_clk) then
         if (alat = '1') then    
            addr(15 downto 0) <= t_addr(15 downto 0);
            ba <= t_ba;
            bs <= t_bs;
            rd <= t_rw_n;
            wr <= not t_rw_n;
         end if;
      end if;
   end process;

   -- latch the LIC and AVMA control signals when stable (CLAT strobe)
   process(sys_clk, clat, t_lic, t_avma)
   begin
      if rising_edge(sys_clk) then
         if (clat = '1') then 
            lic <= t_lic;
            vma <= t_avma;
         end if;
      end if;
   end process;

   -- data bus buffer enabled during "delayed E"
   -- note: change this later to consider AVMA and not bother $FFFF all the time!
   t_dben_n <= not busen;         
   
   -- data buffer direction is high when CPU is reading, low when CPU is writing   
   t_dbdir <= rd;            
   
   -- address bus buffer always enabled
   t_aben_n <= '0';

   -- map the address decoder
   decode0 : entity work.decode port map ( 
      reset => reset,            -- global reset (active high)
  	  addr => addr,           -- latched CPU address
      busen => busen,            -- delayed E clock
      romsel => romsel,          -- upper 1K ROM addressed
      ramsel => ramsel,          -- lower 1K RAM addressed
      iosel => iosel             -- I/O page (0xE0xx) addressed
   );

   -- SRAM is never enabled in this phase
   t_ram_oe_n <= '1';
   t_ram_cs_n <= '1';
   t_ram_we_n <= '1';
   
   -- DAT is never enabled in this phase
   dat_enable <= '0';
	dat_page <= "00000000";
   
   -- DMA is never enabled in this phase
   sram_dma <= '0';
   addr_out <= "00000000000000000000";
   
   -- create the internal input port and output port "chip selects" 
   oportcs <= '1' when (iosel = '1' and addr(7 downto 0) = "00000000") else '0';
   iportcs <= '1' when (iosel = '1' and addr(7 downto 0) = "00000001") else '0';
   
   -- create a simple 1 bit output port 
   -- LED4 at bit 0, BUSY at bit 1
   process(sys_clk, oportcs, iowe, wr, reset)
   begin
      if (reset = '1') then
         op_data_q(7 downto 0) <= "00000000";      
      elsif rising_edge(sys_clk) then
         if(oportcs = '1' and iowe = '1' and wr = '1') then 
            op_data_q(1 downto 0) <= data_in(1 downto 0);
         end if;
      end if;
   end process;
   t_led_4 <= op_data_q(0);
   t_led_busy <= op_data_q(1);
   
   -- create a simple 1 bit input port 
   -- PB at bit0, CONF1 at bit 1, CONF2 at bit 2, RTS at bit 3, CARD at bit 4
   process(sys_clk, iportcs, alat, reset)
   begin
      if (reset = '1') then
         ip_data_q(7 downto 0) <= "00000000";      
      elsif rising_edge(sys_clk) then
         if (alat = '1') then            -- read input state prior to BUSEN
            ip_data_q(0) <= t_btn;           
            ip_data_q(1) <= t_conf_1;
            ip_data_q(2) <= t_conf_2;
            ip_data_q(3) <= t_eci_rts;
         end if;
      end if;
   end process;

   -- create seven segement CS and WR signals                                                                    
   sevencs <= '1' when (iosel = '1' and addr(7 downto 0) = "00000010") else '0';
   sevenwr <= sevencs and wr;
   
   -- instantiate a seven-segment LED display port
   sevenseg0 : entity work.seven_seg port map ( 
      reset => reset,                    -- global reset (active high)
      clk => sys_clk,                    -- 50 MHz master clock 
      wr => sevenwr,                     -- register write enable
      data_i => data_in,                 -- input data from CPU
      data_q => seven_data_q,             -- output data to CPU
      digit_h => dig_2,
	   digit_l => dig_3,             -- digit anode drivers
      segment => seg_full                -- segmenet cathode drivers
   );

   -- Resolve onchip register outputs onto tri-state DATA bus
   data_in <= t_data;
   t_data  <= op_data_q when (oportcs = '1' and rd = '1') else
			     ip_data_q when (iportcs = '1' and rd = '1') else
              seven_data_q when (sevencs = '1' and rd = '1') else
			     (others => 'Z');		
              
   -- resolve bidirectional address bus 
   addr_in <= t_addr;
   t_maddr(19 downto 16) <= addr_out(19 downto 16) when (sram_dma = '1') else -- addr_out during DMA
                            dat_page(7 downto 4) when (dat_enable = '1') else -- dat_page when DAT enabled
                            "0000";                                           -- 0000 otherwise
                            
   t_maddr(15 downto 12) <= addr_out(15 downto 12) when (sram_dma = '1') else -- addr_out during DMA
                            dat_page(3 downto 0) when (dat_enable = '1') else -- dat_page when DAT enabled
                            "0000";                                           -- 0000 otherwise
									 
   t_maddr(11)           <= addr_out(11) when (sram_dma = '1') else           -- addr_out during DMA
                            addr(11);		   											-- otherwise drive with A11 from CPU

   t_addr(10 downto 0)   <= addr_out(10 downto 0) when (sram_dma = '1') else  -- addr_out during DMA
                            (others => 'Z');                                  -- CPU drives A10-A10 otherwise
                            
   -- take care of unused hardware resources
   uart_tx <= uart_rx;              -- loopback mainboard USB bridge

   t_halt_n <= '1';                 -- do not HALT the CPU
   t_irq_n <= '1';                  -- do not IRQ the CPU
   t_nmi_n <= '1';                  -- do not NMI the CPU

   t_sci_tx <= t_sci_rx;            -- SCI serial loopback
   t_eci_tx <= t_eci_rx;            -- ECI serial data input into USB bridge 
   
   t_sda <= 'Z';        -- I2C SDA bidirectional signal
   t_scl <= 'Z';        -- I2C SCL output signal
   
   t_ee_cs_n <= '1';                -- deselect Boot ROM Image EEPROM
   t_ee_clk <= '0';                 -- SPI EEPROM CLK
   t_ee_mosi <= '0';                -- SPI EEPROM MOSI

   t_sd_cs_n <= '1';                -- deselect SD card
   t_sd_clk <= '0';                 -- SD Card SPI CLK
   t_sd_mosi <= '0';                -- SD Card SPI MOSI
				
end behavioral;
			

	
	
	
	
	


	
