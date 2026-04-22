const std = @import("std");
const common = @import("../common.zig");
const arm_isa = @import("arm_isa.zig");

pub const hword = common.hword;
pub const word = common.word;

pub const ThumbOpcode = enum(u4) {
    and_,
    eor,
    lsl,
    lsr,
    asr,
    adc,
    sbc,
    ror,
    tst,
    neg,
    cmp,
    cmn,
    orr,
    mul,
    bic,
    mvn,
};

pub const ThumbInstr = packed union {
    h: hword,
    nibbles: packed struct(hword) {
        n0: u4,
        n1: u4,
        n2: u4,
        n3: u4,
    },
    shift: packed struct(hword) {
        rd: u3,
        rs: u3,
        offset: u5,
        op: u2,
        c1: u3,
    },
    add: packed struct(hword) {
        rd: u3,
        rs: u3,
        op2: u3,
        op: bool,
        i: bool,
        c1: u5,
    },
    alu_imm: packed struct(hword) {
        offset: u8,
        rd: u3,
        op: u2,
        c1: u3,
    },
    alu: packed struct(hword) {
        rd: u3,
        rs: u3,
        opcode: ThumbOpcode,
        c1: u6,
    },
    hi_ops: packed struct(hword) {
        rd: u3,
        rs: u3,
        h2: bool,
        h1: bool,
        op: u2,
        c1: u6,
    },
    ld_pc: packed struct(hword) {
        offset: u8,
        rd: u3,
        c1: u5,
    },
    ldst_reg: packed struct(hword) {
        rd: u3,
        rb: u3,
        ro: u3,
        c2: u1,
        b: bool,
        l: bool,
        c1: u4,
    },
    ldst_s: packed struct(hword) {
        rd: u3,
        rb: u3,
        ro: u3,
        c2: u1,
        s: bool,
        h: bool,
        c1: u4,
    },
    ldst_imm: packed struct(hword) {
        rd: u3,
        rb: u3,
        offset: u5,
        l: bool,
        b: bool,
        c1: u3,
    },
    ldst_h: packed struct(hword) {
        rd: u3,
        rb: u3,
        offset: u5,
        l: bool,
        c1: u4,
    },
    ldst_sp: packed struct(hword) {
        offset: u8,
        rd: u3,
        l: bool,
        c1: u4,
    },
    ld_addr: packed struct(hword) {
        offset: u8,
        rd: u3,
        sp: bool,
        c1: u4,
    },
    add_sp: packed struct(hword) {
        offset: u7,
        s: bool,
        c1: u8,
    },
    push_pop: packed struct(hword) {
        rlist: u8,
        r: bool,
        c2: u2,
        l: bool,
        c1: u4,
    },
    ldst_m: packed struct(hword) {
        rlist: u8,
        rb: u3,
        l: bool,
        c1: u4,
    },
    b_cond: packed struct(hword) {
        offset: u8,
        cond: arm_isa.Condition,
        c1: u4,
    },
    swi: packed struct(hword) {
        arg: u8,
        c1: u8,
    },
    branch: packed struct(hword) {
        offset: u11,
        c1: u5,
    },
    branch_l: packed struct(hword) {
        offset: u11,
        h: bool,
        c1: u4,
    },
};

pub var thumb_lookup: [1 << 16]arm_isa.ArmInstr = [_]arm_isa.ArmInstr{.{ .w = 0 }} ** (1 << 16);

pub fn generate_lookup() void {
    var i: usize = 0;
    while (i < thumb_lookup.len) : (i += 1) {
        thumb_lookup[i] = decode_instr(.{ .h = @intCast(i) });
    }
}

pub fn decode_instr(instr: ThumbInstr) arm_isa.ArmInstr {
    var dec = arm_isa.ArmInstr{ .w = 0 };
    dec.cond_base.cond = .al;

    switch (instr.nibbles.n3) {
        0, 1 => {
            if (instr.shift.op < 0b11) {
                dec.data_proc.c1 = 0b00;
                dec.data_proc.i = false;
                dec.data_proc.opcode = .mov;
                dec.data_proc.s = true;
                dec.data_proc.rd = instr.shift.rd;
                dec.data_proc.op2 = instr.shift.rs;
                dec.data_proc.op2 |= @as(u12, instr.shift.op) << 5;
                dec.data_proc.op2 |= @as(u12, instr.shift.offset) << 7;
            } else {
                dec.data_proc.c1 = 0b00;
                dec.data_proc.i = instr.add.i;
                dec.data_proc.opcode = if (instr.add.op) .sub else .add;
                dec.data_proc.s = true;
                dec.data_proc.rn = instr.add.rs;
                dec.data_proc.rd = instr.add.rd;
                dec.data_proc.op2 = instr.add.op2;
            }
        },
        2, 3 => {
            dec.data_proc.c1 = 0b00;
            dec.data_proc.i = true;
            dec.data_proc.s = true;
            dec.data_proc.rn = instr.alu_imm.rd;
            dec.data_proc.rd = instr.alu_imm.rd;
            dec.data_proc.op2 = instr.alu_imm.offset;
            dec.data_proc.opcode = switch (instr.alu_imm.op) {
                0 => .mov,
                1 => .cmp,
                2 => .add,
                else => .sub,
            };
        },
        4 => switch (instr.nibbles.n2 >> 2) {
            0 => {
                dec.data_proc.c1 = 0b00;
                dec.data_proc.i = false;
                dec.data_proc.opcode = switch (instr.alu.opcode) {
                    .and_ => .and_,
                    .eor => .eor,
                    .lsl => .mov,
                    .lsr => .mov,
                    .asr => .mov,
                    .adc => .adc,
                    .sbc => .sbc,
                    .ror => .mov,
                    .tst => .tst,
                    .neg => .rsb,
                    .cmp => .cmp,
                    .cmn => .cmn,
                    .orr => .orr,
                    .mul => .mov,
                    .bic => .bic,
                    .mvn => .mvn,
                };
                dec.data_proc.s = true;
                dec.data_proc.rn = instr.alu.rd;
                dec.data_proc.rd = instr.alu.rd;
                dec.data_proc.op2 = instr.alu.rs;
                switch (instr.alu.opcode) {
                    .lsl => {
                        dec.data_proc.opcode = .mov;
                        dec.data_proc.op2 = instr.alu.rd;
                        dec.data_proc.op2 |= 1 << 4;
                        dec.data_proc.op2 |= (@as(u12, @intFromEnum(arm_isa.ShiftType.lsl)) << 5);
                        dec.data_proc.op2 |= @as(u12, instr.alu.rs) << 8;
                    },
                    .lsr => {
                        dec.data_proc.opcode = .mov;
                        dec.data_proc.op2 = instr.alu.rd;
                        dec.data_proc.op2 |= 1 << 4;
                        dec.data_proc.op2 |= (@as(u12, @intFromEnum(arm_isa.ShiftType.lsr)) << 5);
                        dec.data_proc.op2 |= @as(u12, instr.alu.rs) << 8;
                    },
                    .asr => {
                        dec.data_proc.opcode = .mov;
                        dec.data_proc.op2 = instr.alu.rd;
                        dec.data_proc.op2 |= 1 << 4;
                        dec.data_proc.op2 |= (@as(u12, @intFromEnum(arm_isa.ShiftType.asr)) << 5);
                        dec.data_proc.op2 |= @as(u12, instr.alu.rs) << 8;
                    },
                    .ror => {
                        dec.data_proc.opcode = .mov;
                        dec.data_proc.op2 = instr.alu.rd;
                        dec.data_proc.op2 |= 1 << 4;
                        dec.data_proc.op2 |= (@as(u12, @intFromEnum(arm_isa.ShiftType.ror)) << 5);
                        dec.data_proc.op2 |= @as(u12, instr.alu.rs) << 8;
                    },
                    .neg => {
                        dec.data_proc.i = true;
                        dec.data_proc.opcode = .rsb;
                        dec.data_proc.rn = instr.alu.rs;
                        dec.data_proc.op2 = 0;
                    },
                    .mul => {
                        dec.multiply.c1 = 0;
                        dec.multiply.a = false;
                        dec.multiply.s = true;
                        dec.multiply.rd = instr.alu.rd;
                        dec.multiply.rn = 0;
                        dec.multiply.rs = instr.alu.rd;
                        dec.multiply.c2 = 0b1001;
                        dec.multiply.rm = instr.alu.rs;
                    },
                    else => {},
                }
            },
            1 => {
                dec.data_proc.c1 = 0b00;
                dec.data_proc.i = false;
                dec.data_proc.s = false;
                dec.data_proc.rn = instr.hi_ops.rd | (@as(u4, @intFromBool(instr.hi_ops.h1)) << 3);
                dec.data_proc.rd = instr.hi_ops.rd | (@as(u4, @intFromBool(instr.hi_ops.h1)) << 3);
                dec.data_proc.op2 = instr.hi_ops.rs | (@as(u12, @intFromBool(instr.hi_ops.h2)) << 3);
                switch (instr.hi_ops.op) {
                    0 => dec.data_proc.opcode = .add,
                    1 => {
                        dec.data_proc.opcode = .cmp;
                        dec.data_proc.s = true;
                    },
                    2 => dec.data_proc.opcode = .mov,
                    3 => {
                        dec.branch_ex.c3 = 0b0001;
                        dec.branch_ex.c1 = 0b00010010;
                        dec.branch_ex.rn = instr.hi_ops.rs | (@as(u4, @intFromBool(instr.hi_ops.h2)) << 3);
                    },
                }
            },
            2, 3 => {
                dec.single_trans.c1 = 0b01;
                dec.single_trans.i = false;
                dec.single_trans.p = true;
                dec.single_trans.u = true;
                dec.single_trans.w = false;
                dec.single_trans.b = false;
                dec.single_trans.l = true;
                dec.single_trans.rn = 15;
                dec.single_trans.rd = instr.ld_pc.rd;
                dec.single_trans.offset = @as(u12, instr.ld_pc.offset) << 2;
            },
            else => unreachable,
        },
        5 => {
            if (instr.ldst_reg.c2 == 0) {
                dec.single_trans.c1 = 0b01;
                dec.single_trans.i = true;
                dec.single_trans.p = true;
                dec.single_trans.u = true;
                dec.single_trans.w = false;
                dec.single_trans.b = instr.ldst_reg.b;
                dec.single_trans.l = instr.ldst_reg.l;
                dec.single_trans.rn = instr.ldst_reg.rb;
                dec.single_trans.rd = instr.ldst_reg.rd;
                dec.single_trans.offset = instr.ldst_reg.ro;
            } else {
                dec.half_trans.c1 = 0b000;
                dec.half_trans.p = true;
                dec.half_trans.u = true;
                dec.half_trans.i = false;
                dec.half_trans.w = false;
                dec.half_trans.l = instr.ldst_s.s or instr.ldst_s.h;
                dec.half_trans.rn = instr.ldst_s.rb;
                dec.half_trans.rd = instr.ldst_s.rd;
                dec.half_trans.c2 = 1;
                dec.half_trans.s = instr.ldst_s.s;
                dec.half_trans.h = !instr.ldst_s.s or instr.ldst_s.h;
                dec.half_trans.c3 = 1;
                dec.half_trans.offlo = instr.ldst_s.ro;
            }
        },
        6, 7 => {
            dec.single_trans.c1 = 0b01;
            dec.single_trans.i = false;
            dec.single_trans.p = true;
            dec.single_trans.u = true;
            dec.single_trans.w = false;
            dec.single_trans.b = instr.ldst_imm.b;
            dec.single_trans.l = instr.ldst_imm.l;
            dec.single_trans.rn = instr.ldst_imm.rb;
            dec.single_trans.rd = instr.ldst_imm.rd;
            dec.single_trans.offset = if (instr.ldst_imm.b)
                instr.ldst_imm.offset
            else
                @as(u12, instr.ldst_imm.offset) << 2;
        },
        8 => {
            dec.half_trans.c1 = 0b000;
            dec.half_trans.p = true;
            dec.half_trans.u = true;
            dec.half_trans.i = true;
            dec.half_trans.w = false;
            dec.half_trans.l = instr.ldst_h.l;
            dec.half_trans.rn = instr.ldst_h.rb;
            dec.half_trans.rd = instr.ldst_h.rd;
            dec.half_trans.offhi = @truncate(instr.ldst_h.offset >> 3);
            dec.half_trans.c2 = 1;
            dec.half_trans.s = false;
            dec.half_trans.h = true;
            dec.half_trans.c3 = 1;
            dec.half_trans.offlo = @truncate(instr.ldst_h.offset << 1);
        },
        9 => {
            dec.single_trans.c1 = 0b01;
            dec.single_trans.i = false;
            dec.single_trans.p = true;
            dec.single_trans.u = true;
            dec.single_trans.w = false;
            dec.single_trans.b = false;
            dec.single_trans.l = instr.ldst_sp.l;
            dec.single_trans.rn = 13;
            dec.single_trans.rd = instr.ldst_sp.rd;
            dec.single_trans.offset = @as(u12, instr.ldst_sp.offset) << 2;
        },
        10 => {
            dec.data_proc.c1 = 0b00;
            dec.data_proc.i = true;
            dec.data_proc.opcode = .add;
            dec.data_proc.s = false;
            dec.data_proc.rd = instr.ld_addr.rd;
            dec.data_proc.rn = if (instr.ld_addr.sp) 13 else 15;
            dec.data_proc.op2 = @as(u12, instr.ld_addr.offset) << 2;
        },
        11 => {
            if (instr.add_sp.c1 == 0b10110000) {
                dec.data_proc.c1 = 0b00;
                dec.data_proc.i = true;
                dec.data_proc.opcode = if (instr.add_sp.s) .sub else .add;
                dec.data_proc.s = false;
                dec.data_proc.rd = 13;
                dec.data_proc.rn = 13;
                dec.data_proc.op2 = @as(u12, instr.add_sp.offset) << 2;
            } else {
                dec.block_trans.c1 = 0b100;
                dec.block_trans.p = !instr.push_pop.l;
                dec.block_trans.u = instr.push_pop.l;
                dec.block_trans.s = false;
                dec.block_trans.w = true;
                dec.block_trans.l = instr.push_pop.l;
                dec.block_trans.rn = 13;
                dec.block_trans.rlist = instr.push_pop.rlist;
                if (instr.push_pop.r) {
                    if (instr.push_pop.l) {
                        dec.block_trans.rlist |= 1 << 15;
                    } else {
                        dec.block_trans.rlist |= 1 << 14;
                    }
                }
            }
        },
        12 => {
            dec.block_trans.c1 = 0b100;
            dec.block_trans.p = false;
            dec.block_trans.u = true;
            dec.block_trans.s = false;
            dec.block_trans.w = true;
            dec.block_trans.l = instr.ldst_m.l;
            dec.block_trans.rn = instr.ldst_m.rb;
            dec.block_trans.rlist = instr.ldst_m.rlist;
        },
        13 => {
            if (@intFromEnum(instr.b_cond.cond) < 0b1111) {
                dec.cond_base.cond = instr.b_cond.cond;
                dec.branch.c1 = 0b101;
                dec.branch.l = false;
                var offset: word = instr.b_cond.offset;
                if ((offset & (@as(word, 1) << 7)) != 0) offset |= 0xffff_ff00;
                dec.branch.offset = @truncate(offset);
            } else {
                dec.sw_intr.c1 = 0b1111;
                dec.sw_intr.arg = instr.swi.arg;
            }
        },
        14 => {
            dec.branch.c1 = 0b101;
            dec.branch.l = false;
            var offset: word = instr.branch.offset;
            if ((offset & (@as(word, 1) << 10)) != 0) offset |= 0xffff_f800;
            dec.branch.offset = @truncate(offset);
        },
        15 => {
            dec.branch.c1 = 0b101;
            dec.branch.l = true;
            if (instr.branch_l.h) {
                dec.branch.offset = instr.branch_l.offset;
                dec.branch.offset |= 1 << 22;
            } else {
                dec.branch.offset = @as(u24, instr.branch_l.offset) << 11;
            }
        },
    }

    return dec;
}

test "decode thumb mov immediate becomes ARM mov" {
    const instr = ThumbInstr{ .h = 0x2001 };
    const dec = decode_instr(instr);
    try std.testing.expectEqual(arm_isa.ArmOpcode.mov, dec.data_proc.opcode);
    try std.testing.expect(dec.data_proc.i);
}
