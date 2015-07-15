// ID.v

module ID (
    input clk,    // Clock
    input rst_n,  // Asynchronous reset active low

    input uart_signal,  // 1: there is new data from uart
    input uart_flag,    // 0: uart_register1, 1: uart_register2
    input [7:0] uart_rx_data,   // Data from uart

    input [31:0] instruction,   // Get instruction from IF_ID[31:0]
    input [31:0] PC_plus4,      // Get PC+4 from IF_ID[63:32]
    
    input RegWrite,     // From WB_RegWrite
    input [4:0] WriteRegister,  // From WB_WriteRegister
    input [31:0] RegWriteData,  // From WB_RegWriteData

    input EX_MemRead,   // Input for hazard unit to detect hazard
    input [4:0] EX_WriteRegister,   // Input for hazard unit to detect hazard

    // Output for uart
    output [7:0] uart_result_data,

    // Output for IF
    output Z,   // Whether goto branch target
    output J,   // Whether it's a Jump instruction
    output JR,  // Whether it's a Jump Register instruction
    output PC_IF_ID_Write,  // Enable for PC and IF_ID
    output [31:0] branch_target, 
    output [31:0] jump_target, 
    output [31:0] jr_target,

    output [:0] ID_EX
);

// for WB
wire [1:0] ID_MemtoReg;   // 0: ALU, 1: Mem
wire ID_RegWrite; 

// for MEM
wire ID_MemRead; 
wire ID_MemWrite;

// for EX
wire [5:0] ID_ALUFun;
wire ID_ALUSrc1;
wire ID_ALUSrc2;
wire [1:0] ID_RegDst;   // Target register to write; 00: rd, 01: rt, 10: ra, 11: k0

// for Control
wire interrupt;
wire exception;     // Undefined instruction
wire [2:0] PCSrc;
wire Branch;
wire ExtOp;         // Extend imm16 to imm32
wire LuOp;
wire [4:0] ALUOp;

// for Register
wire [4:0] ID_Rd;
wire [4:0] ID_Rs; 
wire [4:0] ID_Rt; 
wire [31:0] ID_RsData;
wire [31:0] ID_RtData;

assign ID_Rd = instruction[15:11];
assign ID_Rs = instruction[25:21];
assign ID_Rt = instruction[20:16];

Control C1(
    // Input
    .PCH        (PC_plus4[31]), 
    .Instruction(instruction), 
    .stall      (interrupt), 
    // Output
    .UI         (exception),
    .PCSrc      (PCSrc),
    .Branch     (Branch),
    .RegWrite   (ID_RegWrite),
    .RegDst     (ID_RegDst),
    .MemRead    (ID_MemRead),
    .MemWrite   (ID_MemWrite),
    .MemtoReg   (ID_MemtoReg),
    .ALUSrc1    (ID_ALUSrc1),
    .ALUSrc2    (ID_ALUSrc2),
    .ExtOp      (ExtOp),
    .LuOp       (LuOp),
    .ALUOp      (ALUOp)
);

RegisterFile R1(
    // Input
    .reset          (rst_n),
    .clk            (clk),
    .stall          (interrupt),
    .UI             (exception),
    .signal         (uart_signal),
    .flag           (uart_flag),
    .rx_data        (uart_rx_data),
    .RegWrite       (RegWrite),
    .Read_register1 (ID_Rs),
    .Read_register2 (ID_Rt),
    .Write_register1(WriteRegister),
    .Write_register2(5'd26),
    .Write_register3(5'd26),
    .Write_data1    (RegWriteData),
    .Write_data2    (PC_plus4 - 4),
    .Write_data3    (PC_plus4),
    // Output
    .Read_data1     (ID_RsData),
    .Read_data2     (ID_RtData),
    .result_data    (uart_result_data)
);

ZeroTest Z1(
    // Input
    .ALUOp (ALUOp),
    .RsData(ID_RsData),
    .RtData(ID_RtData),
    // Output
    .Z     (Z)
);

wire [31:0] imm32;

assign imm32 = ExtOp ? {16{instruction[15]}, instruction[15:0]} :
                       {16'b0, instruction[15:0]};

assign branch_target = PC_plus4 + {imm32[29:0], 2'b00};

assign J = (PCSrc == 3'b001);
assign jump_target = {PC_plus4[31:28], instruction[25:0], 2'b00};

assign JR = (PCSrc == 3'b010);
assign jr_target = ID_RsData;

wire bubble;    // Clear control signals in ID_EX

HazardDetector H1(
    // Input
    .EX_MemRead      (EX_MemRead),
    .EX_WriteRegister(EX_WriteRegister),
    .ID_Rs           (ID_Rs),
    .ID_Rt           (ID_Rt),
    // Output
    .PC_IF_ID_Write  (PC_IF_ID_Write),
    .bubble          (bubble)
);

wire [31:0] LuOut;  // Select by LuOp

assign LuOut = LuOp ? {instruction[15:0], 16'b0} : imm32;

// Write to ID_EX
always @(posedge clk or negedge rst_n) begin
    if(~rst_n) begin
        ID_EX <= 0;
    end else begin
        ID_EX[31:0] <= ID_RtData;
        ID_EX[63:32] <= ID_RsData;
        ID_EX[68:64] <= ID_Rt;
        ID_EX[73:68] <= ID_Rs;
        ID_EX[78:74] <= ID_Rd;
        ID_EX[110:79] <= imm32;
        ID_EX[142:111] <= LuOut;
        if(~bubble) begin
            ID_EX[152:143] <= {ID_ALUFun, ID_ALUSrc1, ID_ALUSrc2, ID_RegDst};   // Control for EX
            ID_EX[154:153] <= {ID_MemRead, ID_MemWrite};    // for MEM
            ID_EX[157:155] <= {ID_MemtoReg, ID_RegWrite};   // for WB
        end else begin
            ID_EX[157:143] <= 0;
        end
    end
end

endmodule


module ZeroTest (
    input [4:0] ALUOp,
    input [31:0] RsData,
    input [31:0] RtData,

    output reg Z    // 1: goto branch target
);

wire eq;    // 1: if RsData == RtData
wire zero;  // 1: if RsData == 0

assign eq = (RsData == RtData);
assign zero = (RsData == 32'b0);

always @(*) begin
    case (ALUop[3:0])
        4'b0001 : Z <= eq;  // beq
        4'b0011 : Z <= ~eq; // bne
        4'b0110 : Z <= RsData[31] | zero;    // blez
        4'b0111 : Z <= ~RsData[31] & ~zero;  // bgtz
        4'b1000 : Z <= ~RsData[31] | zero;   // bgez
        default : Z <= 0;
    endcase
end

endmodule


module HazardDetector (
    input EX_MemRead,   // Detect lw
    input [4:0] EX_WriteRegister, 
    input [4:0] ID_Rs,
    input [4:0] ID_Rt,

    output PC_IF_ID_Write,
    output bubble   // Bubble, clear control signals in ID_EX
);

assign bubble = (EX_MemRead == 1
                && (EX_WriteRegister == ID_Rs
                || EX_WriteRegister == ID_Rt));

assign PC_IF_ID_Write = ~bubble;

endmodule
