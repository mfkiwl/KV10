//	-*- mode: Verilog; fill-column: 96 -*-
//
// Arithmetic Processing Unit for kv10 processor
//

`timescale 1 ns / 1 ns

`include "constants.vh"
`include "alu.vh"

module apr
  (
   input 	      clk,
   input 	      reset,
   // interface to memory and I/O
   output reg [`ADDR] mem_addr,
   input [`WORD]      mem_read_data,
   output [`WORD]     mem_write_data,
   output reg 	      mem_user, // selects user or exec memory
   output reg 	      mem_mem_write, // only one of mem_write, mem_read, io_write, or io_read
   output reg 	      mem_mem_read,
   output reg 	      io_write,
   output reg 	      io_read,
   input 	      mem_write_ack,
   input 	      mem_read_ack,
   input 	      mem_nxm, // !!! don't do anything with this yet
   input 	      mem_page_fail,
   input [1:7] 	      io_pi_req, // PI requests from I/O devices

   // these might grow to be part of a front-panel interface one day
   output reg [`ADDR] display_addr, 
   output reg 	      running
    );

`include "functions.vh"
`include "io.vh"
`include "opcodes.vh"
`include "decode.vh"
   

   //
   // Interrupt Logic
   //

   reg 		      pi_ge;	// Global Enable
   reg [1:7] 	      pi_le;	// Level Enable
   reg [1:7] 	      pi_sr;	// Software request
   reg [1:7] 	      pi_ip;	// PI In-Progress
   reg [1:7] 	      pi_trap;	// trap interrupts from the APR
   reg [1:7] 	      pi_error;	// error interrupts from the APR
   reg [1:7] 	      pi_second; // execute the second interrupt instruction
   wire [1:7] 	      pi_hr = pi_trap | pi_error | io_pi_req; // hardware request
   wire [1:7] 	      pi_ir = pi_sr | (pi_le & pi_hr); // interrupt request - software requests
 						       // happen even if the level enable is off
   reg [`ADDR] 	      pi_vector; // Vector Address for the current interrupt level
   
	 
   task RESET_PI;
      pi_ge <= 0;
      pi_le <= 0;
      pi_sr <= 0;
      pi_ip <= 0;
      pi_trap <= 0;
      pi_error <= 0;
      pi_second <= 0;
   endtask

   typedef bit [`ADDR] addr;	// this typdef needs to move to a header file !!!
   task set_pi_vector;
      input integer level;
      pi_vector = addr'('o40 + (2*level) + integer'(pi_second[level]));
   endtask

   always @(*) begin
      case (1'b1)
	pi_ir[1]: set_pi_vector(1);
	pi_ir[2]: set_pi_vector(2);
	pi_ir[3]: set_pi_vector(3);
	pi_ir[4]: set_pi_vector(4);
	pi_ir[5]: set_pi_vector(5);
	pi_ir[6]: set_pi_vector(6);
	pi_ir[7]: set_pi_vector(7);
	default:  set_pi_vector(0); // used for UUOs !!!
      endcase	
   end


   //
   // The APR and PI devices
   //

   reg 		      io_read_ack, io_write_ack, io_nxd;
   reg [`WORD] 	      io_read_data;


   // these all need to move to the module interface !!!
   reg 		      ext_io_read_ack, ext_io_write_ack, ext_io_nxd;
   reg [`WORD] 	      ext_io_read_data;

   // Internal I/O Control Line Mux
   always @(*) begin
      io_read_ack = 1;
      io_write_ack = 1;
      io_nxd = 0;
      
      case ({io_dev, io_cond})
	IO_DATA(APR): io_nxd = 1; // not yet implemented !!!
	IO_COND(APR): io_nxd = 1; // not yet implemented !!!
	IO_DATA(PI):  io_nxd = 1; // not yet implemented !!!
	IO_COND(PI):  ;
	default:
	  begin
	     io_nxd = ext_io_nxd;
	     io_read_ack = ext_io_read_ack;
	     io_write_ack = ext_io_write_ack;
	  end
      endcase // case ({io_dev, io_cond})
   end
   
   // Internal I/I Device Read
   always @(posedge clk)
     if (io_read)
       case ({io_dev, io_cond})
	 IO_DATA(APR): io_read_data <= 0;
	 IO_COND(APR): io_read_data <= 0;
	 IO_DATA(PI): io_read_data <= 0;
	 IO_COND(PI): io_read_data <= { 11'b0, pi_sr, 3'b0, pi_ip, pi_ge, pi_le };
	 default: 
	   if (ext_io_read_ack)
	     io_read_data <= ext_io_read_data;
       endcase

   // Internal I/O Device Write
   always @(posedge clk) begin
      if (reset) begin
	 RESET_PI();
      end else if (io_write) begin
	 case ({io_dev, io_cond})
	   IO_DATA(APR):
	     ;
	   
	   IO_COND(APR):
	     ;

	   IO_DATA(PI):
	     ;

	   IO_COND(PI):
	     if (write_data[PI_RPI]) begin
		RESET_PI();
	     end else begin
		// Matching the KX10, we prioritize setting over clearing.
		if (write_data[PI_SSR])
		  pi_sr <= pi_sr | write_data[`PI_Mask];
		else if (write_data[PI_CSR])
		  pi_sr <= pi_sr & ~write_data[`PI_Mask];

		if (write_data[PI_SLE])
		  pi_le <= pi_le | write_data[`PI_Mask];
		else if (write_data[PI_CLE])
		  pi_le <= pi_le & ~write_data[`PI_Mask];

		if (write_data[PI_SGE])
		  pi_ge <= 1;
		else if (write_data[PI_CGE])
		  pi_ge <= 0;
	     end // else: !if(write_data[PI_RPI])
	 endcase
      end
   end

   //
   // Data Paths
   //

   // Fast Accumulators
   reg [`WORD] 	      accumulators [0:'o17];
   reg 		      AC_write,
		      AC_mem_write;
`ifdef SIM
   initial begin
      accumulators[0] = 'o070707_707070;
      accumulators[1] = 'o070707_707070;
      accumulators[2] = 'o070707_707070;
      accumulators[3] = 'o070707_707070;
      accumulators[4] = 'o070707_707070;
      accumulators[5] = 'o070707_707070;
      accumulators[6] = 'o070707_707070;
      accumulators[7] = 'o070707_707070;
      accumulators[8] = 'o070707_707070;
      accumulators[9] = 'o070707_707070;
      accumulators[10] = 'o070707_707070;
      accumulators[11] = 'o070707_707070;
      accumulators[12] = 'o070707_707070;
      accumulators[13] = 'o070707_707070;
      accumulators[14] = 'o070707_707070;
      accumulators[15] = 'o070707_707070;
   end
`endif   

   // dual-port, synchronous write
   always @(posedge clk) begin
      if (AC_write)
	accumulators[ACsel] <= write_data;
      if (AC_mem_write)
	accumulators[mem_addr[32:35]] <= write_data;
   end
   // dual-port, asynchronous read
   wire [`WORD]       AC = accumulators[ACsel];
`ifdef NOTDEF
   wire [`WORD]       AC_mem = accumulators[mem_addr[32:35]];
`else
   // when we read from the accumulators as if they're memory, do a synchronous read
   reg [`WORD] 	      AC_mem;
   always @(posedge clk)
     if (mem_read)
       AC_mem <= accumulators[mem_addr[32:35]];
`endif

   // An assortment of other registers in the micro-machine
   reg [`WORD] 	      Breg;	// scratchpad for double-word operations
   reg [`WORD] 	      Areg;	// scratchpad for the A leg of the ALU
   reg [`WORD] 	      Mreg;	// scratchpad for the M leg of the ALU
   reg [`ADDR] 	      PC;	// Program Counter
   reg [0:12] 	      OpA;	// Op and A fields of the instruction
   reg [13:17] 	      IX;	// I and X fields of the instruction
   reg [18:35] 	      Y;	// Y field of the instruction
   wire [`WORD]       inst = { OpA, IX, Y }; // put the whole instruction together
   wire 	      Indirect = instI(inst);
   wire [0:3] 	      X = instX(inst);
   wire 	      Index = (X != 0);
   wire [`ADDR]       E = Y;	       // Y is also used for E
   wire [0:3] 	      A = instA(inst); // Pull out the A field
   reg [0:5] 	      BP_P;	       // Position field of byte pointer
   reg [0:5] 	      BP_S;	       // Size field of byte pointer
   // write these registers under control of the micro-machine
   reg 		      Breg_load, Areg_load, Mreg_load,
		      OpA_load, IX_load, Y_load, BP_load,
		      PC_load;
   always @(posedge clk) begin
      if (Breg_load) Breg <= ALUresultlow;
      
      if (Areg_load) 
	Areg <= write_data;
      else if (mul_start)
	Areg <= 0;		// a hack to save a state
      
      if (Mreg_load) Mreg <= write_data;
      if (PC_load)
	PC <= RIGHT(Amux);
      if (OpA_load) OpA <= { instOP(write_data), instA(write_data) };
      if (IX_load)
	IX <= { instI(write_data), instX(write_data) };
      if (Y_load) Y <= instY(write_data);
      if (BP_load) { BP_P, BP_S } = { P(write_data), S(write_data) };
   end

   // A-leg mux to the ALU
   wire [0:3] 	      Asel;	// set correct size !!!
   reg [`WORD] 	      Amux;
   wire [`ADDR]       PC_next = PC + 1;
   wire [`ADDR]       PC_skip = PC + 2;
   always @(*)
     // numbers here must match those in kv10.def
     case (Asel)
       0: Amux =  `ZERO;
       1: Amux = `ONE;
       2: Amux = `MINUSONE;
       3: Amux = `WORDSIZE'o254000_001000; // jrst 1000
       4: Amux = {`WORDSIZE{Malu[0]}}; // sign-extend Malu
//       5: Amux = PIvector;
       6: Amux = Areg;
       7: Amux = { PSW, PC };
       8: Amux = { PSW, PC_next };
       9: Amux = { PSW, PC_skip };
       10: Amux = AC;
       11: Amux = { RIGHT(AC), LEFT(AC) };
       12: Amux = bp_mask(BP_S);
       13: Amux = Mreg;
       14: Amux = { `HALFSIZE'd0, E };
       default: Amux = AC;
     endcase // case (Asel)

   // M-leg mux to the ALU
   wire [0:3] 	      Msel;	// set correct size !!!
   reg [`WORD] 	      Mmux;
   wire [`HWORD]      extP = { 12'b0, BP_P }; // byte position
   wire [`HWORD]      extPneg = -extP;	      // for shifting bytes to the right
   always @(*)
     // numbers here must match those in kv10.def
     case (Msel)
       0: Mmux = Mreg;
       1: Mmux = AC;
       2: Mmux = { `HALFZERO, 12'b0, BP_P };
       3: Mmux = { `HALFZERO, extPneg };
       4: Mmux = { `HALFZERO, E };
       5: Mmux = read_data;
       6: Mmux = io_read_data;
       7: Mmux = { OpA, 5'b0, Y }; // the instruction except for I and X
       default: Mmux = AC;
     endcase // case (Msel)

   // Select either A or A+1 for double word operations or X for index calculations
   wire 	      ACnext, ACindex; // driven from the micro-instruction
   wire [0:3] 	      ACsel = ACindex ? X : (ACnext ? A + 1 : A);
      
   // some extra state to help with implementing multiply and divide
   wire 	      mul_shift_set = NEGATIVE(Mmux) & Breg[35];
   reg 		      mul_shift_bit;
   wire 	      mul_shift_ctl = mul_shift_bit | mul_shift_set;
   reg 		      mul_start;
   always @(posedge clk)
     if (reset || mul_start) begin
	mul_shift_bit <= 0;
     end else begin
	if (mul_shift_set)
	  mul_shift_bit <= 1;
     end

   // Wire in the ALU
   reg [`aluCMD]      ALUcommand;
   wire [`WORD]       ALUresultlow;
   wire [`WORD]       ALUresult;
   wire 	      ALUcarry0;
   wire 	      ALUcarry1;
   wire 	      ALUoverflow;
   wire 	      ALUzero;
   wire 	      Mswap;
   wire [`WORD]       Malu = Mswap ? { RIGHT(Mmux), LEFT(Mmux) } : Mmux;
   alu alu(ALUcommand, Breg, Amux, Malu, mul_shift_ctl, NEGATIVE(AC), ALUresultlow, ALUresult, 
     ALUcarry0, ALUcarry1, ALUoverflow, ALUzero);
   // rename the output of the ALU
   wire [`WORD]       write_data = ALUresult;
   // Send the output of the ALU to the write data lines for the memory
   assign mem_write_data = write_data;
   // Pull the memory address off the A input to the ALU
   assign mem_addr = RIGHT(Amux);

   //
   // Mux for Memory and ACs
   //

   // Control signals go out immediately
   wire 	      mem_read, mem_write;
   reg [`WORD] 	      read_data;
   reg 		      read_ack, write_ack;
   always @(*)
     if (isAC(mem_addr)) begin
	AC_mem_write = mem_write;
	mem_mem_read = 0;
	mem_mem_write = 0;
	read_ack = mem_read;
	write_ack = mem_write;
     end else begin
	AC_mem_write = 0;
	mem_mem_write = mem_write;
	mem_mem_read = mem_read;
	read_ack = mem_read_ack & mem_read;
	write_ack = mem_write_ack & mem_write;
     end

   // The read_data mux selection is latched
   reg 		      accp;
   always @(posedge clk)
     if (mem_read || mem_write)
       accp = isAC(mem_addr);
   always @(*) read_data = accp ? AC_mem : mem_read_data;

   // Compute a skip or jump condition looking at the ALU output.  This signal only makes
   // sense when the ALU is performing a subtraction.
   reg [0:2] condition_code;	// driven by the instruction decode ROM
   reg 	     jump_condition;
   always @(*)
     case (condition_code) // synopsys full_case parallel_case
       skip_never: jump_condition = 0;
       skipl: jump_condition = !ALUzero & (ALUoverflow ^ NEGATIVE(ALUresult));
       skipe: jump_condition = ALUzero;
       skiple: jump_condition = ALUzero | (ALUoverflow ^ NEGATIVE(ALUresult));
       skipa: jump_condition = 1;
       skipge: jump_condition = ALUzero | !(ALUoverflow ^ NEGATIVE(ALUresult));
       skipn: jump_condition = !ALUzero;
       skipg: jump_condition = !ALUzero & !(ALUoverflow ^ NEGATIVE(ALUresult));
     endcase
   // Compute a skip or jump condition by comparing the ALU output to 0
   reg 	     jump_condition_0;
   always @(*)
     case (condition_code) // synopsys full_case parallel_case
       skip_never: jump_condition_0 = 0;
       skipl: jump_condition_0 = NEGATIVE(ALUresult);
       skipe: jump_condition_0 =  ALUzero;
       skiple: jump_condition_0 = ALUzero | NEGATIVE(ALUresult);
       skipa: jump_condition_0 = 1;
       skipge: jump_condition_0 = ALUzero | !NEGATIVE(ALUresult);
       skipn: jump_condition_0 = !ALUzero;
       skipg: jump_condition_0 = !ALUzero &!NEGATIVE(ALUresult);
     endcase
   
   //
   // Processor Status Word
   //
   reg overflow, carry0, carry1, floating_overflow;
   reg saved_overflow, saved_carry0, saved_carry1;
   reg first_part_done, user, userIO, floating_underflow, no_divide;
   reg set_flags, save_flags, clear_flags, set_overflow;
   reg clear_first_part_done, set_first_part_done, set_no_divide;
   reg PSW_load;
   wire [`HWORD] PSW = { overflow, carry0, carry1, floating_overflow,
			 first_part_done, user, userIO, 4'b0,
			 floating_underflow, no_divide, 5'b0 };
   always @(posedge clk) begin
      // this is a set of latches on the ALU flags to save them for later
      if (save_flags) begin
	 saved_overflow <= ALUoverflow;
	 saved_carry0 <= ALUcarry0;
	 saved_carry1 <= ALUcarry1;
      end

      if (set_flags) begin
	 if ((saved_overflow) || (save_flags && ALUoverflow)) overflow <= 1;
	 if ((saved_carry0) || (save_flags && ALUcarry0)) carry0 <= 1;
	 if ((saved_carry1) || (save_flags && ALUcarry1)) carry1 <= 1;
      end

      if (set_overflow) overflow <= 1;

      if (clear_flags) begin
	 if (inst[9]) overflow <= 0;
	 if (inst[10]) carry0 <= 0;
	 if (inst[11]) carry1 <= 0;
	 if (inst[12]) floating_overflow <= 0;
      end
      
      if (clear_first_part_done) first_part_done <= 0;
      if (set_first_part_done) first_part_done <= 1;
      if (set_no_divide) no_divide <= 1;
      
      if (PSW_load) begin	// load PSW from the left half of write_data
	 overflow <= write_data[0];
	 carry0 <= write_data[1];
	 carry1 <= write_data[2];
	 floating_overflow <= write_data[3];
	 first_part_done <= write_data[4];
	 user <= write_data[5];
	 userIO <= write_data[6];
	 floating_underflow <= write_data[11];
	 no_divide <= write_data[12];
      end
   end


   //
   // Micro-Controller
   //

   // the micro-instruction and its breakout
   reg [63:0] uROM [0:2047];	// microcode ROM
   reg [63:0] uinst;		// set the width once I'm done !!!

   assign mul_start = uinst[60];
   assign set_no_divide = uinst[59];
   assign set_first_part_done = uinst[58];
   assign clear_first_part_done = uinst[57];
   assign set_overflow = uinst[56];
   assign clear_flags = uinst[55];

   assign set_flags = uinst[53];

   assign PSW_load = uinst[51];
   assign ACnext = uinst[50];
   assign ACindex = uinst[49];
   assign BP_load = uinst[48];
   assign Y_load = uinst[47];
   assign IX_load = uinst[46];
   assign OpA_load = uinst[45];

   assign PC_load = uinst[42];
   assign Mreg_load = uinst[41];
   assign Areg_load = uinst[40];
   assign Breg_load = uinst[39];
   assign AC_write = uinst[38];
   
   assign io_write = uinst[37];
   assign io_read = uinst[36];
   assign mem_write = uinst[35];
   assign mem_read = uinst[34];

   assign Mswap = uinst[32];

   assign save_flags = uinst[30];

   assign ALUcommand = uinst[29:24];
   assign Asel = uinst[23:20];
   assign Msel = uinst[19:16];
   wire [4:0] ubranch_code = uinst[15:11];
   wire [10:0] unext = uinst[10:0]; // the next instruction location

   reg [10:0] uaddr, uprev;	// current and previous micro-addresses, kept for debugging
   reg [10:0] ubranch;		// gets ORd with unext to get the next micro-address

   initial $readmemh("kv10.hex", uROM);

   // the core of the microsequencer is trvial
   always @(posedge clk) begin
      if (reset) begin
	 uprev <= 'x;
	 uaddr <= 0;
	 uinst <= uROM[0];
      end
`ifdef SIM
      // what do I do if we hit a halt when not in the simulator?  !!!
      else if (unext == 0) 
	begin
	   $display(" HALT!!!");
	   $display("uEngine halt @%o from %o", uaddr, uprev);
	   $display("Cycles: %0d  Instructions: %0d   Cycles/inst: %f",
		    cycles, instruction_count, $itor(cycles)/$itor(instruction_count));
	   $display("carry0: %b  carry1: %b  overflow: %b  floating overflow: %b",
		    carry0, carry1, overflow, floating_overflow);
	   print_ac();
	   $finish_and_return(1);
	end
`endif
      else begin
	 uprev <= uaddr;
	 uaddr <= unext | ubranch;
	 uinst <= uROM[unext | ubranch];
//`define UDISASM 1
`ifdef UDISASM
	 $display("%o", uaddr);
`endif
      end
   end // always @ (posedge clk)

   // branching is where much of the magic happens in the micro-engine
   always @(*) begin
      ubranch = 0;		// default all the bits to 0
      
      // these numbers need to match up with the numbers in kv10.def
      case (ubranch_code)
	// no branch
	0: ubranch = 0;

	// mem read - a 4-way branch for reading from memory
	1: case (1'b1)
//	     interrupt:		ubranch[1:0] = 3;	// implement interrupts !!!
	     mem_page_fail:	ubranch[1:0] = 2;
	     read_ack:		ubranch[1:0] = 1;
	     default:		ubranch[1:0] = 0;
	   endcase // case (1'b1)

	// mem write - a 3-way branch for writing to memory.  interrupts are only recognized
	// when reading from memory.
	2: case (1'b1)
	     mem_page_fail:	ubranch[1:0] = 2;
	     write_ack:		ubranch[1:0] = 1;
	     default:		ubranch[1:0] = 0;
	   endcase

	// IX - a 3-way branch on index and indirect calculating the Effective Address.  this
	// comes from write_data because the check happens before inst gets written
	3: case (1'b1)
	     instX(write_data) != 0: ubranch[1:0] = 0;
	     instI(write_data): ubranch[1:0] = 1;
	     default: ubranch[1:0] = 2;
	   endcase

	// Indirect - If the Effective Address calculation included an Index register, we need
	// to then check if there's also an Indirect.  This happens after inst is written so
	// take the Indirect bit from there.
	4: ubranch[0] = Indirect;

	// Dispatch - This comes from the instruction decode.  By default it's just the
	// instruction opcode but it also handles the Effective Address calculation (well, it
	// will someday), instructions that need to read the value at E first, and then a few
	// special cases to optimze certain instructions.  Also, I/O instructions are handled
	// specially.
	5: if (ReadE)
	  ubranch[8:0] = 9'o720;
	else
	  ubranch[8:0] = dispatch;

	// Conditional skip or jump
	6: ubranch[0] = jump_condition;

	// Conditional skip or jump with a comparison to 0
	7: ubranch[0] = jump_condition_0;

	// Write Self check - if AC != 0
	8: ubranch[0] = (A != 0);

	// Test - Bitwise compare on the /inputs/ to the ALU.  For the TEST instructions.
	9: ubranch[0] = ((Amux & Malu) != 0);

	// JFCL - if any of the flags are about to be cleared
	10: ubranch[0] = (({overflow, carry0, carry1, floating_overflow} & inst[9:12]) != 0);

	// MUL - break out the different Multiply or Divide instructions
	// 0: IMUL/IDIV	1: IMULI/IDIVI	2: IMULM/IDIVM	3: IMULB/IDIVB
	// 5: MUL/DIV	6: MULI/DIVI	7: MULM/DIVM	7: MULB/DIVB
	11: ubranch[2:0] = inst[6:8];

	// OVR - check ALUoverflow, used in DIV and JFFO
	12: ubranch[0] = ALUoverflow;

	// Byte - Branch on which of four byte instructions
	// 0: ILDB	1: LBD		2: IDPB		3: DPB
	13: ubranch[1:0] = inst[7:8];

	// First Part Done
	14: ubranch[0] = first_part_done;

	// BLT terminates when the word we just wrote went into location E
	15: ubranch[0] = (RIGHT(AC) == E);

	// IO Read - three way branch
	16: case (1'b1)
	      io_nxd: ubranch[1:0] = 2;
	      io_read_ack: ubranch[1:0] = 1;
	      default: ubranch[1:0] = 0;
	    endcase // case (1'b1)

	// IO Write - three way branch
	17: case (1'b1)
	      io_nxd: ubranch[1:0] = 2;
	      io_write_ack: ubranch[1:0] = 1;
	      default: ubranch[1:0] = 0;
	    endcase // case (1'b1)

	default: ubranch = 0;
      endcase // case (ubranch_code)
   end

`ifdef SIM
   //
   // The disassembler
   //

`include "disasm.vh"

   // I need to pull out the cycle and instruction count so they work when I'm not in the
   // simulator too. !!!
   reg [`WORD] 	 cycles;
   reg [`WORD] 	 instruction_count;
   reg [`ADDR] 	 inst_addr;

   always @(posedge clk) begin
      cycles <= cycles+1;

      // When the Op is loaded, remember the instruction address for the disassembler
      if (OpA_load) begin
	 inst_addr <= mem_addr;
	 instruction_count <= instruction_count + 1;
      end
      
      if (reset) begin
	 instruction_count <= 0;
	 cycles <= 0;
	 carry0 <= 0;
	 carry1 <= 0;
	 overflow <= 0;
	 floating_overflow <= 0;
      end

      if (OpA_load) begin
	 // this is a horrible hack but it's really handy for running a bunch of
	 // tests and DaveC's tests all loop back to 001000 !!!
	 if ((PC == `ADDRSIZE'o1000) && (instruction_count != 0)) begin
	    $display("Cycles: %0d  Instructions: %0d   Cycles/inst: %f",
		     cycles, instruction_count, $itor(cycles)/$itor(instruction_count));
	    $finish_and_return(0);
	 end

	 // disassembler
	 $display("%6o: %6o,%6o %s", mem_addr, write_data[0:17], write_data[18:35], disasm(write_data));
      end // if (OpA_load)

`ifdef NOTDEF
      if (ubranch_code == 4) begin	// dispatch
	 if (instX(inst) || instI(inst))
	   $write(" @%6o", E);
	 if (ReadE)
	   $write(" [%6o,%6o]", Mreg[0:17], Mreg[18:35]);
	 if (WriteAC || (WriteSelf && (A != 0)) || WriteE)
	   $write(" %6o,%6o -->", write_data[0:17], write_data[18:35]);
	 if (WriteAC || (WriteSelf && (A != 0)))
	   $write(" AC%o", A);
	 if (WriteE)
	   $write(" [%6o]", E);
	 $display("");		// newline
      end // if (ubranch_code == 4)
`endif //  `ifdef NOTDEF
   end

`endif
   


   //
   // Instruction Decode ROM
   //

   reg ReadE;			// the instruction reads the value from E
   wire dReadE;			// from the decode ROM
   wire [0:8] dispatch;		// main instruction branch in the micro-code
   wire [`DEVICE] io_dev;	// the I/O Device
   wire io_cond; 	  	// I/O Device Conditions
   wire [`WORD] dinst = OpA_load ? write_data : inst;
   decode decode(.inst(dinst),
		 .user(user),
		 .userIO(userIO),
		 .dispatch(dispatch),
 		 .ReadE(dReadE),
		 .condition_code(condition_code),
 		 .io_dev(io_dev),
		 .io_cond(io_cond));
   always @(posedge clk) begin
      // After we read E, clear the flag so we can dispatch again and not read E again
      if (ubranch_code == 5)	// dispatch
	ReadE <= 0;
      // grab ReadE from the decode ROM but into a register that we can clear once we read E
      else if (OpA_load)
	ReadE <= dReadE;
   end


endmodule // APR
