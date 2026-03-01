`timescale 1ns / 1ps

module pipe_MIPS (
    input  wire        clk1,
    input  wire        clk2,
    input  wire        reset,
    output reg  [31:0] ALU_result_out
);

    // Pipeline Registers
    reg [31:0] PC, IF_ID_IR, IF_ID_NPC;
    reg [31:0] ID_EX_IR, ID_EX_NPC, ID_EX_A, ID_EX_B, ID_EX_Imm;
    reg [2:0]  ID_EX_type, EX_MEM_type, MEM_WB_type;
    reg [31:0] EX_MEM_IR, EX_MEM_ALUout, EX_MEM_B;
    reg        EX_MEM_cond;
    reg [31:0] MEM_WB_IR, MEM_WB_ALUout, MEM_WB_LMD;

    // Register Bank and Memory (map to BRAM)
    (* ram_style = "block" *) reg [31:0] Reg [0:31];
    (* ram_style = "block" *) reg [31:0] Mem [0:1023];

    // Opcodes
    localparam ADD  = 6'b000000, SUB  = 6'b000001, AND_ = 6'b000010, OR_  = 6'b000011,
               SLT  = 6'b000100, MUL  = 6'b000101, HLT  = 6'b111111, LW   = 6'b001000,
               SW   = 6'b001001, ADDI = 6'b001010, SUBI = 6'b001011, SLTI = 6'b001100,
               BNEQZ= 6'b001101, BEQZ = 6'b001110;

    // Instruction Types
    localparam RR_ALU = 3'b000, RM_ALU = 3'b001, LOAD = 3'b010, STORE = 3'b011,
               BRANCH = 3'b100, HALT = 3'b101;

    // Control signals (single-driver)
    reg HALTED;         // Assigned only in WB block
    reg TAKEN_BRANCH;   // Assigned only in IF block

    // -----------------------------
    // IF stage (clk1) - single driver for TAKEN_BRANCH
    // -----------------------------
    always @(posedge clk1) begin
        if (reset) begin
            PC <= 32'd0;
            IF_ID_IR <= 32'd0;
            IF_ID_NPC <= 32'd0;
            TAKEN_BRANCH <= 1'b0;
            // HALTED not set here (WB handles HALTED reset)
        end else if (HALTED == 1'b0) begin
            // Branch decision based on EX_MEM values (ex stage produced EX_MEM_ALUout and EX_MEM_cond earlier)
            if ( ((EX_MEM_IR[31:26] == BEQZ) && (EX_MEM_cond == 1'b1)) ||
                 ((EX_MEM_IR[31:26] == BNEQZ) && (EX_MEM_cond == 1'b0)) ) begin
                IF_ID_IR      <= Mem[EX_MEM_ALUout];
                IF_ID_NPC     <= EX_MEM_ALUout + 32'd1;
                PC            <= EX_MEM_ALUout + 32'd1;
                TAKEN_BRANCH  <= 1'b1;
            end else begin
                IF_ID_IR      <= Mem[PC];
                IF_ID_NPC     <= PC + 32'd1;
                PC            <= PC + 32'd1;
                TAKEN_BRANCH  <= 1'b0;
            end
        end
    end

    // -----------------------------
    // ID stage (clk2)
    // -----------------------------
    always @(posedge clk2) begin
        if (HALTED == 1'b0) begin
            // register fetch
            if (IF_ID_IR[25:21] == 5'd0) ID_EX_A <= 32'd0;
            else ID_EX_A <= Reg[IF_ID_IR[25:21]];

            if (IF_ID_IR[20:16] == 5'd0) ID_EX_B <= 32'd0;
            else ID_EX_B <= Reg[IF_ID_IR[20:16]];

            ID_EX_NPC <= IF_ID_NPC;
            ID_EX_IR  <= IF_ID_IR;
            ID_EX_Imm <= {{16{IF_ID_IR[15]}}, IF_ID_IR[15:0]};

            case (IF_ID_IR[31:26])
                ADD, SUB, AND_, OR_, SLT, MUL: ID_EX_type <= RR_ALU;
                ADDI, SUBI, SLTI:             ID_EX_type <= RM_ALU;
                LW:                           ID_EX_type <= LOAD;
                SW:                           ID_EX_type <= STORE;
                BNEQZ, BEQZ:                  ID_EX_type <= BRANCH;
                HLT:                          ID_EX_type <= HALT;
                default:                      ID_EX_type <= HALT;
            endcase
        end
    end

    // -----------------------------
    // EX stage (clk1) - do NOT assign TAKEN_BRANCH or HALTED here
    // -----------------------------
    always @(posedge clk1) begin
        if (HALTED == 1'b0) begin
            EX_MEM_type <= ID_EX_type;
            EX_MEM_IR   <= ID_EX_IR;
            // Evaluate ALU / addresses
            case (ID_EX_type)
                RR_ALU: begin
                    case (ID_EX_IR[31:26])
                        ADD: EX_MEM_ALUout <= ID_EX_A + ID_EX_B;
                        SUB: EX_MEM_ALUout <= ID_EX_A - ID_EX_B;
                        AND_:EX_MEM_ALUout <= ID_EX_A & ID_EX_B;
                        OR_: EX_MEM_ALUout <= ID_EX_A | ID_EX_B;
                        SLT: EX_MEM_ALUout <= (ID_EX_A < ID_EX_B) ? 32'd1 : 32'd0;
                        MUL: EX_MEM_ALUout <= ID_EX_A * ID_EX_B;
                        default: EX_MEM_ALUout <= 32'd0;
                    endcase
                end

                RM_ALU: begin
                    case (ID_EX_IR[31:26])
                        ADDI: EX_MEM_ALUout <= ID_EX_A + ID_EX_Imm;
                        SUBI: EX_MEM_ALUout <= ID_EX_A - ID_EX_Imm;
                        SLTI: EX_MEM_ALUout <= (ID_EX_A < ID_EX_Imm) ? 32'd1 : 32'd0;
                        default: EX_MEM_ALUout <= 32'd0;
                    endcase
                end

                LOAD, STORE: begin
                    EX_MEM_ALUout <= ID_EX_A + ID_EX_Imm;
                    EX_MEM_B <= ID_EX_B;
                end

                BRANCH: begin
                    EX_MEM_ALUout <= ID_EX_NPC + ID_EX_Imm;
                    EX_MEM_cond   <= (ID_EX_A == 32'd0) ? 1'b1 : 1'b0;
                end

                default: begin
                    EX_MEM_ALUout <= 32'd0;
                end
            endcase
        end
    end

    // -----------------------------
    // MEM stage (clk2)
    // -----------------------------
    always @(posedge clk2) begin
        if (HALTED == 1'b0) begin
            MEM_WB_type <= EX_MEM_type;
            MEM_WB_IR   <= EX_MEM_IR;

            case (EX_MEM_type)
                RR_ALU, RM_ALU: begin
                    MEM_WB_ALUout <= EX_MEM_ALUout;
                end

                LOAD: begin
                    MEM_WB_LMD <= Mem[EX_MEM_ALUout];
                end

                STORE: begin
                    if (TAKEN_BRANCH == 1'b0) begin
                        Mem[EX_MEM_ALUout] <= EX_MEM_B;
                    end
                end

                default: begin
                    // no-op
                end
            endcase
        end
    end

    // -----------------------------
    // WB stage (clk1) - single driver for HALTED
    // -----------------------------
    always @(posedge clk1 or posedge reset) begin
        if (reset) begin
            HALTED <= 1'b0;
            // Reg file can be reset if desired:
            // integer i; for (i=0;i<32;i=i+1) Reg[i] <= 32'd0;
        end else begin
            if (TAKEN_BRANCH == 1'b0) begin
                case (MEM_WB_type)
                    RR_ALU: begin
                        Reg[MEM_WB_IR[15:11]] <= MEM_WB_ALUout;
                    end
                    RM_ALU: begin
                        Reg[MEM_WB_IR[20:16]] <= MEM_WB_ALUout;
                    end
                    LOAD: begin
                        Reg[MEM_WB_IR[20:16]] <= MEM_WB_LMD;
                    end
                    HALT: begin
                        HALTED <= 1'b1;
                    end
                    default: begin
                        // no-op
                    end
                endcase
            end
            // Drive the observable output from MEM_WB_ALUout for device visibility
            ALU_result_out <= MEM_WB_ALUout;
        end
    end

endmodule


// ------------------------------------------------------------------
// Top-level wrapper to provide external ports so Vivado keeps logic
// ------------------------------------------------------------------
module processor_top (
    input  wire       clk,
    input  wire       reset,
    output wire [31:0] result
);

    // two-phase clocks derived simply (for mapping/visualization only)
    wire clk1 = clk;
    wire clk2 = ~clk;

    // instantiate core
    pipe_MIPS core (
        .clk1(clk1),
        .clk2(clk2),
        .reset(reset),
        .ALU_result_out() // internal, connect below
    );

    // expose a kept signal from core to top-level result
    // We need a connection to top result so tool won't prune the logic.
    // MEM_WB_ALUout is internal; read it via hierarchical reference
    // Vivado synthesis doesn't allow direct hierarchical continuous assignment,
    // so we use a small wrapper reg inside the core to drive top port.
    // To keep things simple and robust, instantiate core and connect its ALU_result_out to result via IOBUF.
    // But since we connected ALU_result_out as port in core above, re-instantiate properly:

endmodule 
this is my .v file of the processor itself 
