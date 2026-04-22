const std = @import("std");
const common = @import("../common.zig");
const arm7tdmi = @import("arm7tdmi.zig");

pub const byte = common.byte;
pub const hword = common.hword;
pub const word = common.word;
pub const sword = common.sword;
pub const dword = common.dword;
pub const sdword = common.sdword;

pub const Condition = enum(u4) {
    eq,
    ne,
    cs,
    cc,
    mi,
    pl,
    vs,
    vc,
    hi,
    ls,
    ge,
    lt,
    gt,
    le,
    al,
    nv,
};

pub const ArmOpcode = enum(u4) {
    and_,
    eor,
    sub,
    rsb,
    add,
    adc,
    sbc,
    rsc,
    tst,
    teq,
    cmp,
    cmn,
    orr,
    mov,
    bic,
    mvn,
};

pub const ShiftType = enum(u2) {
    lsl,
    lsr,
    asr,
    ror,
};

pub const ArmInstr = packed union {
    w: word,
    cond_base: packed struct(word) {
        instr: u28,
        cond: Condition,
    },
    data_proc: packed struct(word) {
        op2: u12,
        rd: u4,
        rn: u4,
        s: bool,
        opcode: ArmOpcode,
        i: bool,
        c1: u2,
        cond: Condition,
    },
    psr_trans: packed struct(word) {
        op2: u12,
        rd: u4,
        c: bool,
        x: bool,
        s: bool,
        f: bool,
        c3: u1,
        op: bool,
        p: bool,
        c2: u2,
        i: bool,
        c1: u2,
        cond: Condition,
    },
    multiply: packed struct(word) {
        rm: u4,
        c2: u4,
        rs: u4,
        rn: u4,
        rd: u4,
        s: bool,
        a: bool,
        c1: u6,
        cond: Condition,
    },
    multiply_long: packed struct(word) {
        rm: u4,
        c2: u4,
        rs: u4,
        rdlo: u4,
        rdhi: u4,
        s: bool,
        a: bool,
        u: bool,
        c1: u5,
        cond: Condition,
    },
    swap: packed struct(word) {
        rm: u4,
        c4: u4,
        c3: u4,
        rd: u4,
        rn: u4,
        c2: u2,
        b: bool,
        c1: u5,
        cond: Condition,
    },
    branch_ex: packed struct(word) {
        rn: u4,
        c3: u4,
        c2: u12,
        c1: u8,
        cond: Condition,
    },
    half_trans: packed struct(word) {
        offlo: u4,
        c3: u1,
        h: bool,
        s: bool,
        c2: u1,
        offhi: u4,
        rd: u4,
        rn: u4,
        l: bool,
        w: bool,
        i: bool,
        u: bool,
        p: bool,
        c1: u3,
        cond: Condition,
    },
    single_trans: packed struct(word) {
        offset: u12,
        rd: u4,
        rn: u4,
        l: bool,
        w: bool,
        b: bool,
        u: bool,
        p: bool,
        i: bool,
        c1: u2,
        cond: Condition,
    },
    undefined: packed struct(word) {
        u2: u4,
        c2: u1,
        u1: u20,
        c1: u3,
        cond: Condition,
    },
    block_trans: packed struct(word) {
        rlist: u16,
        rn: u4,
        l: bool,
        w: bool,
        s: bool,
        u: bool,
        p: bool,
        c1: u3,
        cond: Condition,
    },
    branch: packed struct(word) {
        offset: u24,
        l: bool,
        c1: u3,
        cond: Condition,
    },
    sw_intr: packed struct(word) {
        arg: u24,
        c1: u4,
        cond: Condition,
    },
};

pub const ArmExecFunc = *const fn (cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) void;

pub var arm_lookup: [1 << 12]ArmExecFunc = undefined;

/// Pré-calcule la table de répartition ARM à partir des bits de décodage de premier niveau.
pub fn generate_lookup() void {
    var i: usize = 0;
    while (i < arm_lookup.len) : (i += 1) {
        arm_lookup[i] = decode_instr(.{
            .w = ((@as(word, @intCast(i & 0x0f)) << 4) | (@as(word, @intCast(i >> 4)) << 20)),
        });
    }
}

pub fn decode_instr(instr: ArmInstr) ArmExecFunc {
    if (instr.sw_intr.c1 == 0b1111) {
        return exec_arm_sw_intr;
    }
    if (instr.branch.c1 == 0b101) {
        return exec_arm_branch;
    }
    if (instr.block_trans.c1 == 0b100) {
        return exec_arm_block_trans;
    }
    if (instr.undefined.c1 == 0b011 and instr.undefined.c2 == 1) {
        return exec_arm_undefined;
    }
    if (instr.single_trans.c1 == 0b01) {
        return exec_arm_single_trans;
    }
    if (instr.branch_ex.c1 == 0b00010010 and instr.branch_ex.c3 == 0b0001) {
        return exec_arm_branch_ex;
    }
    if (instr.swap.c1 == 0b00010 and instr.swap.c2 == 0b00 and instr.swap.c4 == 0b1001) {
        return exec_arm_swap;
    }
    if (instr.multiply.c1 == 0b000000 and instr.multiply.c2 == 0b1001) {
        return exec_arm_multiply;
    }
    if (instr.multiply_long.c1 == 0b00001 and instr.multiply_long.c2 == 0b1001) {
        return exec_arm_multiply_long;
    }
    if (instr.half_trans.c1 == 0b000 and instr.half_trans.c2 == 1 and instr.half_trans.c3 == 1) {
        return exec_arm_half_trans;
    }
    if (instr.psr_trans.c1 == 0b00 and instr.psr_trans.c2 == 0b10 and instr.psr_trans.c3 == 0) {
        return exec_arm_psr_trans;
    }
    return exec_arm_data_proc;
}

pub fn exec_instr(cpu: *arm7tdmi.Arm7Tdmi) void {
    const instr = cpu.cur_instr;
    if (!eval_cond(cpu, instr)) {
        cpu.fetch_instr();
        return;
    }
    const lookup_index = (((instr.w >> 4) & 0x0f) | ((instr.w >> 20) << 4)) & 0x0fff;
    arm_lookup[lookup_index](cpu, instr);
}

fn eval_cond(cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) bool {
    if (instr.cond_base.cond == .al) {
        return true;
    }
    return switch (instr.cond_base.cond) {
        .eq => cpu.cpsr.bits.z,
        .ne => !cpu.cpsr.bits.z,
        .cs => cpu.cpsr.bits.c,
        .cc => !cpu.cpsr.bits.c,
        .mi => cpu.cpsr.bits.n,
        .pl => !cpu.cpsr.bits.n,
        .vs => cpu.cpsr.bits.v,
        .vc => !cpu.cpsr.bits.v,
        .hi => cpu.cpsr.bits.c and !cpu.cpsr.bits.z,
        .ls => !cpu.cpsr.bits.c or cpu.cpsr.bits.z,
        .ge => cpu.cpsr.bits.n == cpu.cpsr.bits.v,
        .lt => cpu.cpsr.bits.n != cpu.cpsr.bits.v,
        .gt => !cpu.cpsr.bits.z and (cpu.cpsr.bits.n == cpu.cpsr.bits.v),
        .le => cpu.cpsr.bits.z or (cpu.cpsr.bits.n != cpu.cpsr.bits.v),
        else => true,
    };
}

fn arm_reg_shifter(shift_type: ShiftType, operand: word, shift_amt: word, carry: *word) word {
    if (shift_amt == 0) {
        return operand;
    }

    if (shift_amt >= 32) {
        return switch (shift_type) {
            .lsl => blk: {
                carry.* = if (shift_amt == 32) operand & 1 else 0;
                break :blk 0;
            },
            .lsr => blk: {
                carry.* = if (shift_amt == 32) operand >> 31 else 0;
                break :blk 0;
            },
            .asr => blk: {
                if ((operand >> 31) != 0) {
                    carry.* = 1;
                    break :blk 0xffff_ffff;
                }
                carry.* = 0;
                break :blk 0;
            },
            .ror => blk: {
                const rot = shift_amt & 31;
                if (rot == 0) {
                    carry.* = operand >> 31;
                    break :blk operand;
                }
                carry.* = (operand >> @as(u5, @truncate(rot - 1))) & 1;
                break :blk common.rot_right32(operand, @truncate(rot));
            },
        };
    }

    return switch (shift_type) {
        .lsl => blk: {
            carry.* = (operand >> @as(u5, @truncate(32 - shift_amt))) & 1;
            break :blk operand << @as(u5, @truncate(shift_amt));
        },
        .lsr => blk: {
            carry.* = (operand >> @as(u5, @truncate(shift_amt - 1))) & 1;
            break :blk operand >> @as(u5, @truncate(shift_amt));
        },
        .asr => blk: {
            carry.* = (operand >> @as(u5, @truncate(shift_amt - 1))) & 1;
            break :blk @bitCast(@as(sword, @bitCast(operand)) >> @as(u5, @truncate(shift_amt)));
        },
        .ror => blk: {
            carry.* = (operand >> @as(u5, @truncate(shift_amt - 1))) & 1;
            break :blk common.rot_right32(operand, @as(u5, @truncate(shift_amt)));
        },
    };
}

fn arm_shifter(cpu: *arm7tdmi.Arm7Tdmi, shift: byte, operand: word, carry: *word) word {
    const shift_type: ShiftType = @enumFromInt((shift >> 1) & 0b11);
    const shift_amt: word = shift >> 3;
    if (shift_amt != 0) {
        const amt: u5 = @truncate(shift_amt);
        return switch (shift_type) {
            .lsl => blk: {
                carry.* = (operand >> @as(u5, @truncate(32 - shift_amt))) & 1;
                break :blk operand << amt;
            },
            .lsr => blk: {
                carry.* = (operand >> @as(u5, @truncate(shift_amt - 1))) & 1;
                break :blk operand >> amt;
            },
            .asr => blk: {
                carry.* = (operand >> @as(u5, @truncate(shift_amt - 1))) & 1;
                break :blk @bitCast(@as(sword, @bitCast(operand)) >> amt);
            },
            .ror => blk: {
                carry.* = (operand >> @as(u5, @truncate(shift_amt - 1))) & 1;
                break :blk common.rot_right32(operand, amt);
            },
        };
    }

    return switch (shift_type) {
        .lsl => operand,
        .lsr => blk: {
            carry.* = operand >> 31;
            break :blk 0;
        },
        .asr => blk: {
            carry.* = operand >> 31;
            break :blk if ((operand >> 31) != 0) 0xffff_ffff else 0;
        },
        .ror => blk: {
            carry.* = operand & 1;
            break :blk (operand >> 1) | (@as(word, @intFromBool(cpu.cpsr.bits.c)) << 31);
        },
    };
}

pub fn exec_arm_data_proc(cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) void {
    var op1: word = 0;
    var op2: word = 0;

    var z: word = @intFromBool(cpu.cpsr.bits.z);
    var c: word = @intFromBool(cpu.cpsr.bits.c);
    var n: word = @intFromBool(cpu.cpsr.bits.n);
    var v: word = @intFromBool(cpu.cpsr.bits.v);

    if (instr.data_proc.i) {
        if (cpu.cpsr.bits.t) {
            op2 = instr.data_proc.op2;
        } else {
            op2 = instr.data_proc.op2 & 0xff;
            var shift_amt: word = instr.data_proc.op2 >> 8;
            if (shift_amt != 0) {
                shift_amt *= 2;
                c = (op2 >> @as(u5, @truncate(shift_amt - 1))) & 1;
                op2 = common.rot_right32(op2, @truncate(shift_amt));
            }
        }
        op1 = cpu.regs.r[instr.data_proc.rn];
        cpu.fetch_instr();
    } else {
        const rm: u4 = @truncate(instr.data_proc.op2 & 0b1111);
        const shift: word = instr.data_proc.op2 >> 4;

        if ((shift & 1) != 0) {
            cpu.fetch_instr();
            cpu.internal_cycle(1);
            op2 = cpu.regs.r[rm];

            const rs: u4 = @truncate(shift >> 4);
            const shift_amt: word = cpu.regs.r[rs] & 0xff;
            const shift_type: ShiftType = @enumFromInt((shift >> 1) & 0b11);

            op2 = arm_reg_shifter(shift_type, op2, shift_amt, &c);

            op1 = cpu.regs.r[instr.data_proc.rn];
        } else {
            op2 = arm_shifter(cpu, @truncate(shift), cpu.regs.r[rm], &c);
            op1 = cpu.regs.r[instr.data_proc.rn];
            cpu.fetch_instr();
        }
    }

    if (instr.data_proc.rn == 15 and instr.data_proc.rd != 15) {
        op1 &= ~@as(word, 0b10);
    }

    if (instr.data_proc.s) {
        var res: word = 0;
        var arith = false;
        var car: word = 0;
        var save = true;

        switch (instr.data_proc.opcode) {
            .and_ => res = op1 & op2,
            .eor => res = op1 ^ op2,
            .sub => {
                arith = true;
                op2 = ~op2;
                car = 1;
            },
            .rsb => {
                arith = true;
                const tmp = op1;
                op1 = op2;
                op2 = ~tmp;
                car = 1;
            },
            .add => arith = true,
            .adc => {
                arith = true;
                car = @intFromBool(cpu.cpsr.bits.c);
            },
            .sbc => {
                arith = true;
                op2 = ~op2;
                car = @intFromBool(cpu.cpsr.bits.c);
            },
            .rsc => {
                arith = true;
                const tmp = op1;
                op1 = op2;
                op2 = ~tmp;
                car = @intFromBool(cpu.cpsr.bits.c);
            },
            .tst => {
                res = op1 & op2;
                save = false;
            },
            .teq => {
                res = op1 ^ op2;
                save = false;
            },
            .cmp => {
                arith = true;
                op2 = ~op2;
                car = 1;
                save = false;
            },
            .cmn => {
                arith = true;
                save = false;
            },
            .orr => res = op1 | op2,
            .mov => res = op2,
            .bic => res = op1 & ~op2,
            .mvn => res = ~op2,
        }

        if (arith) {
            const sum = @as(dword, op1) + @as(dword, op2) + @as(dword, car);
            res = @truncate(sum);
            c = @intFromBool((sum >> 32) != 0);
            v = @intFromBool(((op1 >> 31) == (op2 >> 31)) and ((op1 >> 31) != (res >> 31)));
        }
        z = @intFromBool(res == 0);
        n = (res >> 31) & 1;

        if (instr.data_proc.rd == 15) {
            const mode = cpu.cpsr.bits.m;
            if (!(mode == .user or mode == .system)) {
                cpu.cpsr.w = cpu.spsr;
                cpu.update_mode(mode);
            }
        } else {
            cpu.cpsr.bits.z = z != 0;
            cpu.cpsr.bits.n = n != 0;
            cpu.cpsr.bits.c = c != 0;
            cpu.cpsr.bits.v = v != 0;
        }
        if (save) {
            cpu.regs.r[instr.data_proc.rd] = res;
            if (instr.data_proc.rd == 15) {
                cpu.flush();
            }
        }
        return;
    }

    const rd = instr.data_proc.rd;
    switch (instr.data_proc.opcode) {
        .and_ => cpu.regs.r[rd] = op1 & op2,
        .eor => cpu.regs.r[rd] = op1 ^ op2,
        .sub => cpu.regs.r[rd] = op1 -% op2,
        .rsb => cpu.regs.r[rd] = op2 -% op1,
        .add => cpu.regs.r[rd] = op1 +% op2,
        .adc => cpu.regs.r[rd] = op1 +% op2 +% @as(word, @intFromBool(cpu.cpsr.bits.c)),
        .sbc => cpu.regs.r[rd] = op1 -% op2 -% 1 +% @as(word, @intFromBool(cpu.cpsr.bits.c)),
        .rsc => cpu.regs.r[rd] = op2 -% op1 -% 1 +% @as(word, @intFromBool(cpu.cpsr.bits.c)),
        .tst, .teq, .cmp, .cmn => return,
        .orr => cpu.regs.r[rd] = op1 | op2,
        .mov => cpu.regs.r[rd] = op2,
        .bic => cpu.regs.r[rd] = op1 & ~op2,
        .mvn => cpu.regs.r[rd] = ~op2,
    }
    if (rd == 15) {
        cpu.flush();
    }
}

pub fn exec_arm_psr_trans(cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) void {
    if (instr.psr_trans.op) {
        var op2: word = 0;
        if (instr.psr_trans.i) {
            op2 = instr.psr_trans.op2 & 0xff;
            const rot: u5 = @truncate(instr.psr_trans.op2 >> 7);
            op2 = common.rot_right32(op2, rot);
        } else {
            const rm: u4 = @truncate(instr.psr_trans.op2 & 0b1111);
            op2 = cpu.regs.r[rm];
        }

        var mask: word = 0;
        if (instr.psr_trans.f) mask |= 0xff00_0000;
        if (instr.psr_trans.s) mask |= 0x00ff_0000;
        if (instr.psr_trans.x) mask |= 0x0000_ff00;
        if (instr.psr_trans.c) mask |= 0x0000_00ff;
        if (cpu.cpsr.bits.m == .user) mask &= 0xf000_0000;
        op2 &= mask;

        if (instr.psr_trans.p) {
            cpu.spsr &= ~mask;
            cpu.spsr |= op2;
        } else {
            const mode = cpu.cpsr.bits.m;
            cpu.cpsr.w &= ~mask;
            cpu.cpsr.w |= op2;
            cpu.update_mode(mode);
        }
    } else {
        const psr = if (instr.psr_trans.p) cpu.spsr else cpu.cpsr.w;
        cpu.regs.r[instr.psr_trans.rd] = psr;
    }
    cpu.fetch_instr();
}

pub fn exec_arm_multiply(cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) void {
    cpu.fetch_instr();
    var op: sword = @bitCast(cpu.regs.r[instr.multiply.rs]);
    var cycles: u32 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        op >>= 8;
        cycles += 1;
        if (op == 0 or op == -1) break;
    }

    var res = cpu.regs.r[instr.multiply.rm] *% cpu.regs.r[instr.multiply.rs];
    if (instr.multiply.a) {
        cycles += 1;
        res +%= cpu.regs.r[instr.multiply.rn];
    }
    cpu.internal_cycle(cycles);
    cpu.regs.r[instr.multiply.rd] = res;
    if (instr.multiply.s) {
        cpu.cpsr.bits.z = cpu.regs.r[instr.multiply.rd] == 0;
        cpu.cpsr.bits.n = ((cpu.regs.r[instr.multiply.rd] >> 31) & 1) != 0;
    }
}

pub fn exec_arm_multiply_long(cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) void {
    cpu.fetch_instr();
    cpu.internal_cycle(1);

    var op: sword = @bitCast(cpu.regs.r[instr.multiply_long.rs]);
    var cycles: u32 = 0;
    var i: usize = 1;
    while (i <= 4) : (i += 1) {
        cycles += 1;
        op >>= 8;
        if (op == 0 or (op == -1 and instr.multiply_long.u)) break;
    }

    const acc = if (instr.multiply_long.a)
        @as(dword, cpu.regs.r[instr.multiply_long.rdlo]) |
            (@as(dword, cpu.regs.r[instr.multiply_long.rdhi]) << 32)
    else
        0;
    if (instr.multiply_long.a) {
        cycles += 1;
    }

    const multiply_out = booth_multiply_long(
        cpu.regs.r[instr.multiply_long.rm],
        cpu.regs.r[instr.multiply_long.rs],
        acc,
        instr.multiply_long.u,
    );
    const res = multiply_out.output;

    cpu.internal_cycle(cycles);
    if (instr.multiply_long.s) {
        cpu.cpsr.bits.z = res == 0;
        cpu.cpsr.bits.n = ((res >> 63) & 1) != 0;
        cpu.cpsr.bits.c = multiply_out.carry;
    }
    cpu.regs.r[instr.multiply_long.rdlo] = @truncate(res);
    cpu.regs.r[instr.multiply_long.rdhi] = @truncate(res >> 32);
}

const BoothRecodingOutput = struct {
    recoded_output: dword,
    carry: bool,
};

const BoothCsaOutput = struct {
    output: dword,
    carry: dword,
};

const BoothAdderOutput = struct {
    output: word,
    carry: bool,
};

const BoothMultiplyOutput = struct {
    output: dword,
    carry: bool,
};

const BoothU128 = struct {
    lo: dword,
    hi: dword,
};

fn booth_mask(bits: u7) dword {
    if (bits >= 64) {
        return std.math.maxInt(dword);
    }
    return (@as(dword, 1) << @as(u6, @intCast(bits))) - 1;
}

fn booth_sign_extend(value: dword, bits: u7) dword {
    if (bits >= 64) {
        return value;
    }
    const shift: u6 = @intCast(64 - bits);
    const signed_value: sdword = @bitCast(value << shift);
    return @bitCast(signed_value >> shift);
}

fn booth_sign_extend_to(value: dword, src_bits: u7, dst_bits: u7) dword {
    return booth_sign_extend(value & booth_mask(src_bits), src_bits) & booth_mask(dst_bits);
}

fn booth_asr(value: dword, amount: u6, bits: u7) dword {
    const signed_value: sdword = @bitCast(booth_sign_extend(value, bits));
    return @as(dword, @bitCast(signed_value >> amount)) & booth_mask(bits);
}

fn booth_ror_u128(input: BoothU128, shift: u6) BoothU128 {
    if (shift == 0) {
        return input;
    }
    const inv_shift: u6 = @intCast(@as(u7, 64) - shift);
    return .{
        .lo = (input.lo >> shift) | (input.hi << inv_shift),
        .hi = (input.hi >> shift) | (input.lo << inv_shift),
    };
}

fn booth_recode(input: dword, booth_chunk: u3) BoothRecodingOutput {
    var output = BoothRecodingOutput{ .recoded_output = 0, .carry = false };
    switch (booth_chunk) {
        0 => output = .{ .recoded_output = 0, .carry = false },
        1, 2 => output = .{ .recoded_output = input, .carry = false },
        3 => output = .{ .recoded_output = 2 *% input, .carry = false },
        4 => output = .{ .recoded_output = ~(2 *% input), .carry = true },
        5, 6 => output = .{ .recoded_output = ~input, .carry = true },
        7 => output = .{ .recoded_output = 0, .carry = false },
    }
    output.recoded_output &= 0x3ffff_ffff;
    return output;
}

fn booth_csa(a: dword, b: dword, c: dword) BoothCsaOutput {
    return .{
        .output = a ^ b ^ c,
        .carry = (a & b) | (b & c) | (c & a),
    };
}

fn booth_get_recoded(multiplicand: dword, multiplier: dword) [4]BoothRecodingOutput {
    var outputs = [_]BoothRecodingOutput{.{ .recoded_output = 0, .carry = false }} ** 4;
    var i: usize = 0;
    while (i < outputs.len) : (i += 1) {
        outputs[i] = booth_recode(multiplicand, @intCast((multiplier >> @as(u6, @intCast(2 * i))) & 0b111));
    }
    return outputs;
}

fn booth_perform_csa_array(partial_sum: dword, partial_carry: dword, addends: [4]BoothRecodingOutput, acc_shift_register: *dword) BoothCsaOutput {
    var csa_output = BoothCsaOutput{ .output = partial_sum, .carry = partial_carry };
    var final_output = BoothCsaOutput{ .output = 0, .carry = 0 };

    var i: usize = 0;
    while (i < addends.len) : (i += 1) {
        csa_output.output &= 0x1ffff_ffff;
        csa_output.carry &= 0x1ffff_ffff;

        var result = booth_csa(
            csa_output.output,
            addends[i].recoded_output & 0x1ffff_ffff,
            csa_output.carry,
        );

        result.carry <<= 1;
        result.carry |= @intFromBool(addends[i].carry);

        final_output.output |= (result.output & 0x3) << @as(u6, @intCast(2 * i));
        final_output.carry |= (result.carry & 0x3) << @as(u6, @intCast(2 * i));

        result.output >>= 2;
        result.carry >>= 2;

        const magic = @as(dword, @intCast((acc_shift_register.* & 1) + @intFromBool(((csa_output.carry >> 32) & 1) == 0) + @intFromBool(((addends[i].recoded_output >> 33) & 1) == 0)));
        result.output |= magic << 31;
        result.carry |= @as(dword, @intFromBool(((acc_shift_register.* >> 1) & 1) == 0)) << 32;
        acc_shift_register.* >>= 2;
        csa_output = result;
    }

    final_output.output |= csa_output.output << 8;
    final_output.carry |= csa_output.carry << 8;
    return final_output;
}

fn booth_should_terminate(multiplier: dword, signed_mul: bool) bool {
    if (signed_mul) {
        return multiplier == 0x1ffff_ffff or multiplier == 0;
    }
    return multiplier == 0;
}

fn booth_adder(a: word, b: word, carry_in: bool) BoothAdderOutput {
    const real_output: dword = @as(dword, a) + @as(dword, b) + @as(dword, @intFromBool(carry_in));
    return .{
        .output = @truncate(real_output),
        .carry = real_output > std.math.maxInt(word),
    };
}

fn booth_multiply_long(rm: word, rs: word, accumulator: dword, signed_mul: bool) BoothMultiplyOutput {
    var csa_output = BoothCsaOutput{ .output = 0, .carry = 0 };
    var multiplier: dword = rs;
    var multiplicand: dword = rm;
    const alu_carry_in = (multiplier & 1) != 0;

    if (signed_mul) {
        multiplier = booth_sign_extend_to(multiplier, 32, 34);
        multiplicand = booth_sign_extend_to(multiplicand, 32, 34);
    } else {
        multiplier &= 0x1ffff_ffff;
        multiplicand &= 0x1ffff_ffff;
    }

    csa_output.carry = if ((multiplier & 1) != 0) ~multiplicand else 0;
    csa_output.output = accumulator;
    var acc_shift_register: dword = accumulator >> 34;

    var partial_sum = BoothU128{ .lo = 0, .hi = 0 };
    var partial_carry = BoothU128{ .lo = 0, .hi = 0 };
    partial_sum.lo = csa_output.output & 1;
    partial_carry.lo = csa_output.carry & 1;
    csa_output.output >>= 1;
    csa_output.carry >>= 1;
    partial_sum = booth_ror_u128(partial_sum, 1);
    partial_carry = booth_ror_u128(partial_carry, 1);

    var num_iterations: u3 = 0;
    while (true) {
        const addends = booth_get_recoded(multiplicand, multiplier);
        csa_output = booth_perform_csa_array(csa_output.output, csa_output.carry, addends, &acc_shift_register);
        partial_sum.lo |= csa_output.output & 0xff;
        partial_carry.lo |= csa_output.carry & 0xff;
        csa_output.output >>= 8;
        csa_output.carry >>= 8;
        partial_sum = booth_ror_u128(partial_sum, 8);
        partial_carry = booth_ror_u128(partial_carry, 8);
        multiplier = booth_asr(multiplier, 8, 33);
        num_iterations += 1;
        if (booth_should_terminate(multiplier, signed_mul)) {
            break;
        }
    }

    partial_sum.lo |= csa_output.output;
    partial_carry.lo |= csa_output.carry;

    const correction_ror: u6 = switch (num_iterations) {
        1 => 23,
        2 => 15,
        3 => 7,
        else => 31,
    };
    partial_sum = booth_ror_u128(partial_sum, correction_ror);
    partial_carry = booth_ror_u128(partial_carry, correction_ror);

    if (num_iterations == 4) {
        const adder_output_lo = booth_adder(@truncate(partial_sum.hi), @truncate(partial_carry.hi), alu_carry_in);
        const adder_output_hi = booth_adder(@truncate(partial_sum.hi >> 32), @truncate(partial_carry.hi >> 32), adder_output_lo.carry);
        return .{
            .output = (@as(dword, adder_output_hi.output) << 32) | adder_output_lo.output,
            .carry = ((partial_carry.hi >> 63) & 1) != 0,
        };
    }

    const adder_output_lo = booth_adder(@truncate(partial_sum.hi >> 32), @truncate(partial_carry.hi >> 32), alu_carry_in);
    var shift_amount: u7 = 1 + 8 * @as(u7, num_iterations);
    shift_amount += 1;
    partial_carry.lo = booth_sign_extend_to(partial_carry.lo, shift_amount, 64);
    partial_sum.lo |= acc_shift_register << @as(u6, @intCast(shift_amount));
    const adder_output_hi = booth_adder(@truncate(partial_sum.lo), @truncate(partial_carry.lo), adder_output_lo.carry);
    return .{
        .output = (@as(dword, adder_output_hi.output) << 32) | adder_output_lo.output,
        .carry = ((partial_carry.hi >> 63) & 1) != 0,
    };
}

pub fn exec_arm_swap(cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) void {
    const addr = cpu.regs.r[instr.swap.rn];
    cpu.fetch_instr();
    if (instr.swap.b) {
        cpu.regs.r[instr.swap.rd] = cpu.swapb(addr, @truncate(cpu.regs.r[instr.swap.rm]));
    } else {
        cpu.regs.r[instr.swap.rd] = cpu.swapw(addr, cpu.regs.r[instr.swap.rm]);
    }
    cpu.next_seq = false;
}

pub fn exec_arm_branch_ex(cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) void {
    cpu.fetch_instr();
    cpu.set_pc(cpu.regs.r[instr.branch_ex.rn]);
    cpu.cpsr.bits.t = (cpu.regs.r[instr.branch_ex.rn] & 1) != 0;
    cpu.flush();
}

pub fn exec_arm_half_trans(cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) void {
    var addr = cpu.regs.r[instr.half_trans.rn];
    var offset: word = 0;
    if (instr.half_trans.i) {
        offset = instr.half_trans.offlo | (@as(word, instr.half_trans.offhi) << 4);
    } else {
        offset = cpu.regs.r[instr.half_trans.offlo];
    }
    cpu.fetch_instr();

    if (!instr.half_trans.u) offset = 0 -% offset;
    const wback = addr +% offset;
    if (instr.half_trans.p) addr = wback;

    if (instr.half_trans.s) {
        if (instr.half_trans.l) {
            if (instr.half_trans.w or !instr.half_trans.p) {
                cpu.regs.r[instr.half_trans.rn] = wback;
            }
            if (instr.half_trans.h) {
                cpu.regs.r[instr.half_trans.rd] = cpu.readh(addr, true);
            } else {
                cpu.regs.r[instr.half_trans.rd] = cpu.readb(addr, true);
            }
            cpu.internal_cycle(1);
            if (instr.half_trans.rd == 15) cpu.flush();
        }
        return;
    }

    if (!instr.half_trans.h) return;

    if (instr.half_trans.l) {
        if (instr.half_trans.w or !instr.half_trans.p) {
            cpu.regs.r[instr.half_trans.rn] = wback;
        }
        cpu.regs.r[instr.half_trans.rd] = cpu.readh(addr, false);
        cpu.internal_cycle(1);
        if (instr.half_trans.rd == 15) cpu.flush();
        return;
    }

    cpu.writeh(addr, @truncate(cpu.regs.r[instr.half_trans.rd]));
    if (instr.half_trans.w or !instr.half_trans.p) {
        cpu.regs.r[instr.half_trans.rn] = wback;
    }
    cpu.next_seq = false;
}

pub fn exec_arm_single_trans(cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) void {
    var addr = cpu.regs.r[instr.single_trans.rn];
    if (instr.single_trans.rn == 15) addr &= ~@as(word, 0b10);

    var offset: word = 0;
    if (instr.single_trans.i) {
        const rm: u4 = @truncate(instr.single_trans.offset & 0b1111);
        offset = cpu.regs.r[rm];
        const shift: byte = @truncate(instr.single_trans.offset >> 4);
        var carry: word = 0;
        offset = arm_shifter(cpu, shift, offset, &carry);
    } else {
        offset = instr.single_trans.offset;
    }

    cpu.fetch_instr();

    if (!instr.single_trans.u) offset = 0 -% offset;
    const wback = addr +% offset;
    if (instr.single_trans.p) addr = wback;

    if (instr.single_trans.b) {
        if (instr.single_trans.l) {
            if (instr.single_trans.w or !instr.single_trans.p) {
                cpu.regs.r[instr.single_trans.rn] = wback;
            }
            cpu.regs.r[instr.single_trans.rd] = cpu.readb(addr, false);
            cpu.internal_cycle(1);
            if (instr.single_trans.rd == 15) cpu.flush();
            return;
        }

        cpu.writeb(addr, @truncate(cpu.regs.r[instr.single_trans.rd]));
        if (instr.single_trans.w or !instr.single_trans.p) {
            cpu.regs.r[instr.single_trans.rn] = wback;
        }
        cpu.next_seq = false;
        return;
    }

    if (instr.single_trans.l) {
        if (instr.single_trans.w or !instr.single_trans.p) {
            cpu.regs.r[instr.single_trans.rn] = wback;
        }
        cpu.regs.r[instr.single_trans.rd] = cpu.readw(addr);
        cpu.internal_cycle(1);
        if (instr.single_trans.rd == 15) cpu.flush();
        return;
    }

    cpu.writew(addr, cpu.regs.r[instr.single_trans.rd]);
    if (instr.single_trans.w or !instr.single_trans.p) {
        cpu.regs.r[instr.single_trans.rn] = wback;
    }
    cpu.next_seq = false;
}

pub fn exec_arm_undefined(cpu: *arm7tdmi.Arm7Tdmi, _: ArmInstr) void {
    cpu.handle_interrupt(.und);
}

pub fn exec_arm_block_trans(cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) void {
    var rcount: usize = 0;
    var rlist: [16]u4 = [_]u4{0} ** 16;
    var addr = cpu.regs.r[instr.block_trans.rn];
    var wback = addr;

    if (instr.block_trans.rlist != 0) {
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if ((instr.block_trans.rlist & (@as(u16, 1) << @intCast(i))) != 0) {
                rlist[rcount] = @intCast(i);
                rcount += 1;
            }
        }
        if (instr.block_trans.u) {
            wback +%= 4 * @as(word, @intCast(rcount));
        } else {
            wback -%= 4 * @as(word, @intCast(rcount));
            addr = wback;
        }
    } else {
        rcount = 1;
        rlist[0] = 15;
        if (instr.block_trans.u) {
            wback +%= 0x40;
        } else {
            wback -%= 0x40;
            addr = wback;
        }
    }

    if (instr.block_trans.p == instr.block_trans.u) addr +%= 4;
    cpu.fetch_instr();

    const user_trans = instr.block_trans.s and !(((instr.block_trans.rlist & (@as(u16, 1) << 15)) != 0) and instr.block_trans.l);
    const mode = cpu.cpsr.bits.m;
    if (user_trans) {
        cpu.cpsr.bits.m = .user;
        cpu.update_mode(mode);
    }

    if (instr.block_trans.l) {
        if (instr.block_trans.w) cpu.regs.r[instr.block_trans.rn] = wback;
        var i: usize = 0;
        while (i < rcount) : (i += 1) {
            cpu.regs.r[rlist[i]] = cpu.readm(addr, i);
        }
        cpu.internal_cycle(1);
        if (((instr.block_trans.rlist & (@as(u16, 1) << 15)) != 0) or instr.block_trans.rlist == 0) {
            if (instr.block_trans.s) {
                const cur_mode = cpu.cpsr.bits.m;
                if (!(cur_mode == .user or cur_mode == .system)) {
                    cpu.cpsr.w = cpu.spsr;
                    cpu.update_mode(cur_mode);
                }
            }
            cpu.flush();
        }
    } else {
        var i: usize = 0;
        while (i < rcount) : (i += 1) {
            cpu.writem(addr, i, cpu.regs.r[rlist[i]]);
            if (i == 0 and instr.block_trans.w) {
                cpu.regs.r[instr.block_trans.rn] = wback;
            }
        }
        cpu.next_seq = false;
    }

    if (user_trans) {
        cpu.cpsr.bits.m = mode;
        cpu.update_mode(.user);
    }
}

pub fn exec_arm_branch(cpu: *arm7tdmi.Arm7Tdmi, instr: ArmInstr) void {
    var offset: word = instr.branch.offset;
    if ((offset & (@as(word, 1) << 23)) != 0) {
        offset |= 0xff00_0000;
    }
    if (cpu.cpsr.bits.t) {
        offset <<= 1;
    } else {
        offset <<= 2;
    }

    var dest = cpu.pc_value() +% offset;
    if (instr.branch.l) {
        if (cpu.cpsr.bits.t) {
            if ((offset & (@as(word, 1) << 23)) != 0) {
                offset %= 1 << 23;
                cpu.set_lr(cpu.lr_value() +% offset);
                dest = cpu.lr_value();
                cpu.set_lr((cpu.pc_value() -% 2) | 1);
            } else {
                if ((offset & (@as(word, 1) << 22)) != 0) dest +%= 0xff80_0000;
                cpu.set_lr(dest);
                cpu.fetch_instr();
                return;
            }
        } else {
            cpu.set_lr((cpu.pc_value() -% 4) & ~@as(word, 0b11));
        }
    }
    cpu.fetch_instr();
    cpu.set_pc(dest);
    cpu.flush();
}

pub fn exec_arm_sw_intr(cpu: *arm7tdmi.Arm7Tdmi, _: ArmInstr) void {
    cpu.handle_interrupt(.swi);
}

test "decode branch chooses branch executor" {
    const instr = ArmInstr{ .w = 0xEA00_0000 };
    try std.testing.expect(decode_instr(instr) == exec_arm_branch);
}

test "arm_reg_shifter rotate right by 32 preserves operand and sets carry from bit 31" {
    var carry: word = 0;
    const result = arm_reg_shifter(.ror, 0x8000_0000, 32, &carry);
    try std.testing.expectEqual(@as(word, 0x8000_0000), result);
    try std.testing.expectEqual(@as(word, 1), carry);
}

test "arm_reg_shifter rotate right by 33 rotates once" {
    var carry: word = 1;
    const result = arm_reg_shifter(.ror, 2, 33, &carry);
    try std.testing.expectEqual(@as(word, 1), result);
    try std.testing.expectEqual(@as(word, 0), carry);
}

test "booth_multiply_long matches suite vectors" {
const cases = [_]struct {
    name: []const u8,
    in0: word,
    in1: word,
    sm_lo: word,
    sm_hi: word,
    sm_psr: word,
    um_lo: word,
    um_hi: word,
    um_psr: word,
}{
    .{ .name = "  0 *   0", .in0 = 0x00000000, .in1 = 0x00000000, .sm_lo = 0x00000000, .sm_hi = 0x00000000, .sm_psr = 0x4000001F, .um_lo = 0x00000000, .um_hi = 0x00000000, .um_psr = 0x4000001F },
    .{ .name = "  1 *   0", .in0 = 0x00000001, .in1 = 0x00000000, .sm_lo = 0x00000000, .sm_hi = 0x00000000, .sm_psr = 0x4000001F, .um_lo = 0x00000000, .um_hi = 0x00000000, .um_psr = 0x4000001F },
    .{ .name = " -1 *   0", .in0 = 0xFFFFFFFF, .in1 = 0x00000000, .sm_lo = 0x00000000, .sm_hi = 0x00000000, .sm_psr = 0x4000001F, .um_lo = 0x00000000, .um_hi = 0x00000000, .um_psr = 0x4000001F },
    .{ .name = "$7F *   0", .in0 = 0x7FFFFFFF, .in1 = 0x00000000, .sm_lo = 0x00000000, .sm_hi = 0x00000000, .sm_psr = 0x4000001F, .um_lo = 0x00000000, .um_hi = 0x00000000, .um_psr = 0x4000001F },
    .{ .name = "$80 *   0", .in0 = 0x80000000, .in1 = 0x00000000, .sm_lo = 0x00000000, .sm_hi = 0x00000000, .sm_psr = 0x4000001F, .um_lo = 0x00000000, .um_hi = 0x00000000, .um_psr = 0x4000001F },
    .{ .name = "$81 *   0", .in0 = 0x80000001, .in1 = 0x00000000, .sm_lo = 0x00000000, .sm_hi = 0x00000000, .sm_psr = 0x4000001F, .um_lo = 0x00000000, .um_hi = 0x00000000, .um_psr = 0x4000001F },
    .{ .name = "  0 *   1", .in0 = 0x00000000, .in1 = 0x00000001, .sm_lo = 0x00000000, .sm_hi = 0x00000000, .sm_psr = 0x4000001F, .um_lo = 0x00000000, .um_hi = 0x00000000, .um_psr = 0x4000001F },
    .{ .name = "  1 *   1", .in0 = 0x00000001, .in1 = 0x00000001, .sm_lo = 0x00000000, .sm_hi = 0x00000001, .sm_psr = 0x0000001F, .um_lo = 0x00000000, .um_hi = 0x00000001, .um_psr = 0x0000001F },
    .{ .name = " -1 *   1", .in0 = 0xFFFFFFFF, .in1 = 0x00000001, .sm_lo = 0xFFFFFFFF, .sm_hi = 0xFFFFFFFF, .sm_psr = 0x8000001F, .um_lo = 0x00000000, .um_hi = 0xFFFFFFFF, .um_psr = 0x0000001F },
    .{ .name = "$7F *   1", .in0 = 0x7FFFFFFF, .in1 = 0x00000001, .sm_lo = 0x00000000, .sm_hi = 0x7FFFFFFF, .sm_psr = 0x0000001F, .um_lo = 0x00000000, .um_hi = 0x7FFFFFFF, .um_psr = 0x0000001F },
    .{ .name = "$80 *   1", .in0 = 0x80000000, .in1 = 0x00000001, .sm_lo = 0xFFFFFFFF, .sm_hi = 0x80000000, .sm_psr = 0x8000001F, .um_lo = 0x00000000, .um_hi = 0x80000000, .um_psr = 0x0000001F },
    .{ .name = "$81 *   1", .in0 = 0x80000001, .in1 = 0x00000001, .sm_lo = 0xFFFFFFFF, .sm_hi = 0x80000001, .sm_psr = 0x8000001F, .um_lo = 0x00000000, .um_hi = 0x80000001, .um_psr = 0x0000001F },
    .{ .name = "  0 *  -1", .in0 = 0x00000000, .in1 = 0xFFFFFFFF, .sm_lo = 0x00000000, .sm_hi = 0x00000000, .sm_psr = 0x4000001F, .um_lo = 0x00000000, .um_hi = 0x00000000, .um_psr = 0x4000001F },
    .{ .name = "  1 *  -1", .in0 = 0x00000001, .in1 = 0xFFFFFFFF, .sm_lo = 0xFFFFFFFF, .sm_hi = 0xFFFFFFFF, .sm_psr = 0x8000001F, .um_lo = 0x00000000, .um_hi = 0xFFFFFFFF, .um_psr = 0x0000001F },
    .{ .name = " -1 *  -1", .in0 = 0xFFFFFFFF, .in1 = 0xFFFFFFFF, .sm_lo = 0x00000000, .sm_hi = 0x00000001, .sm_psr = 0x0000001F, .um_lo = 0xFFFFFFFE, .um_hi = 0x00000001, .um_psr = 0xA000001F },
    .{ .name = "$7F *  -1", .in0 = 0x7FFFFFFF, .in1 = 0xFFFFFFFF, .sm_lo = 0xFFFFFFFF, .sm_hi = 0x80000001, .sm_psr = 0x8000001F, .um_lo = 0x7FFFFFFE, .um_hi = 0x80000001, .um_psr = 0x2000001F },
    .{ .name = "$80 *  -1", .in0 = 0x80000000, .in1 = 0xFFFFFFFF, .sm_lo = 0x00000000, .sm_hi = 0x80000000, .sm_psr = 0x0000001F, .um_lo = 0x7FFFFFFF, .um_hi = 0x80000000, .um_psr = 0x0000001F },
    .{ .name = "$81 *  -1", .in0 = 0x80000001, .in1 = 0xFFFFFFFF, .sm_lo = 0x00000000, .sm_hi = 0x7FFFFFFF, .sm_psr = 0x0000001F, .um_lo = 0x80000000, .um_hi = 0x7FFFFFFF, .um_psr = 0x8000001F },
    .{ .name = "  0 * $7F", .in0 = 0x00000000, .in1 = 0x7FFFFFFF, .sm_lo = 0x00000000, .sm_hi = 0x00000000, .sm_psr = 0x4000001F, .um_lo = 0x00000000, .um_hi = 0x00000000, .um_psr = 0x4000001F },
    .{ .name = "  1 * $7F", .in0 = 0x00000001, .in1 = 0x7FFFFFFF, .sm_lo = 0x00000000, .sm_hi = 0x7FFFFFFF, .sm_psr = 0x0000001F, .um_lo = 0x00000000, .um_hi = 0x7FFFFFFF, .um_psr = 0x0000001F },
    .{ .name = " -1 * $7F", .in0 = 0xFFFFFFFF, .in1 = 0x7FFFFFFF, .sm_lo = 0xFFFFFFFF, .sm_hi = 0x80000001, .sm_psr = 0xA000001F, .um_lo = 0x7FFFFFFE, .um_hi = 0x80000001, .um_psr = 0x2000001F },
    .{ .name = "$7F * $7F", .in0 = 0x7FFFFFFF, .in1 = 0x7FFFFFFF, .sm_lo = 0x3FFFFFFF, .sm_hi = 0x00000001, .sm_psr = 0x0000001F, .um_lo = 0x3FFFFFFF, .um_hi = 0x00000001, .um_psr = 0x0000001F },
    .{ .name = "$80 * $7F", .in0 = 0x80000000, .in1 = 0x7FFFFFFF, .sm_lo = 0xC0000000, .sm_hi = 0x80000000, .sm_psr = 0xA000001F, .um_lo = 0x3FFFFFFF, .um_hi = 0x80000000, .um_psr = 0x2000001F },
    .{ .name = "$81 * $7F", .in0 = 0x80000001, .in1 = 0x7FFFFFFF, .sm_lo = 0xC0000000, .sm_hi = 0xFFFFFFFF, .sm_psr = 0xA000001F, .um_lo = 0x3FFFFFFF, .um_hi = 0xFFFFFFFF, .um_psr = 0x2000001F },
    .{ .name = "  0 * $80", .in0 = 0x00000000, .in1 = 0x80000000, .sm_lo = 0x00000000, .sm_hi = 0x00000000, .sm_psr = 0x6000001F, .um_lo = 0x00000000, .um_hi = 0x00000000, .um_psr = 0x4000001F },
    .{ .name = "  1 * $80", .in0 = 0x00000001, .in1 = 0x80000000, .sm_lo = 0xFFFFFFFF, .sm_hi = 0x80000000, .sm_psr = 0xA000001F, .um_lo = 0x00000000, .um_hi = 0x80000000, .um_psr = 0x0000001F },
    .{ .name = " -1 * $80", .in0 = 0xFFFFFFFF, .in1 = 0x80000000, .sm_lo = 0x00000000, .sm_hi = 0x80000000, .sm_psr = 0x0000001F, .um_lo = 0x7FFFFFFF, .um_hi = 0x80000000, .um_psr = 0x2000001F },
    .{ .name = "$7F * $80", .in0 = 0x7FFFFFFF, .in1 = 0x80000000, .sm_lo = 0xC0000000, .sm_hi = 0x80000000, .sm_psr = 0xA000001F, .um_lo = 0x3FFFFFFF, .um_hi = 0x80000000, .um_psr = 0x0000001F },
    .{ .name = "$80 * $80", .in0 = 0x80000000, .in1 = 0x80000000, .sm_lo = 0x40000000, .sm_hi = 0x00000000, .sm_psr = 0x0000001F, .um_lo = 0x40000000, .um_hi = 0x00000000, .um_psr = 0x2000001F },
    .{ .name = "$81 * $80", .in0 = 0x80000001, .in1 = 0x80000000, .sm_lo = 0x3FFFFFFF, .sm_hi = 0x80000000, .sm_psr = 0x0000001F, .um_lo = 0x40000000, .um_hi = 0x80000000, .um_psr = 0x2000001F },
    .{ .name = "  0 * $81", .in0 = 0x00000000, .in1 = 0x80000001, .sm_lo = 0x00000000, .sm_hi = 0x00000000, .sm_psr = 0x6000001F, .um_lo = 0x00000000, .um_hi = 0x00000000, .um_psr = 0x4000001F },
    .{ .name = "  1 * $81", .in0 = 0x00000001, .in1 = 0x80000001, .sm_lo = 0xFFFFFFFF, .sm_hi = 0x80000001, .sm_psr = 0xA000001F, .um_lo = 0x00000000, .um_hi = 0x80000001, .um_psr = 0x0000001F },
    .{ .name = " -1 * $81", .in0 = 0xFFFFFFFF, .in1 = 0x80000001, .sm_lo = 0x00000000, .sm_hi = 0x7FFFFFFF, .sm_psr = 0x0000001F, .um_lo = 0x80000000, .um_hi = 0x7FFFFFFF, .um_psr = 0xA000001F },
    .{ .name = "$7F * $81", .in0 = 0x7FFFFFFF, .in1 = 0x80000001, .sm_lo = 0xC0000000, .sm_hi = 0xFFFFFFFF, .sm_psr = 0xA000001F, .um_lo = 0x3FFFFFFF, .um_hi = 0xFFFFFFFF, .um_psr = 0x0000001F },
    .{ .name = "$80 * $81", .in0 = 0x80000000, .in1 = 0x80000001, .sm_lo = 0x3FFFFFFF, .sm_hi = 0x80000000, .sm_psr = 0x0000001F, .um_lo = 0x40000000, .um_hi = 0x80000000, .um_psr = 0x2000001F },
    .{ .name = "$81 * $81", .in0 = 0x80000001, .in1 = 0x80000001, .sm_lo = 0x3FFFFFFF, .sm_hi = 0x00000001, .sm_psr = 0x0000001F, .um_lo = 0x40000001, .um_hi = 0x00000001, .um_psr = 0x2000001F },
};

    for (cases) |case| {
        const signed_out = booth_multiply_long(case.in0, case.in1, 0, true);
        const signed_lo: word = @truncate(signed_out.output);
        const signed_hi: word = @truncate(signed_out.output >> 32);
        const signed_psr: word =
            (@as(word, @intFromBool(((signed_out.output >> 63) & 1) != 0)) << 31) |
            (@as(word, @intFromBool(signed_out.output == 0)) << 30) |
            (@as(word, @intFromBool(signed_out.carry)) << 29) |
            0x1f;
        if (signed_hi != case.sm_lo or signed_lo != case.sm_hi or signed_psr != case.sm_psr) {
            std.debug.print("signed mismatch {s}: got {x:0>8}:{x:0>8} psr={x:0>8} expected {x:0>8}:{x:0>8} psr={x:0>8}\n", .{ case.name, signed_hi, signed_lo, signed_psr, case.sm_lo, case.sm_hi, case.sm_psr });
            return error.TestExpectedEqual;
        }

        const unsigned_out = booth_multiply_long(case.in0, case.in1, 0, false);
        const unsigned_lo: word = @truncate(unsigned_out.output);
        const unsigned_hi: word = @truncate(unsigned_out.output >> 32);
        const unsigned_psr: word =
            (@as(word, @intFromBool(((unsigned_out.output >> 63) & 1) != 0)) << 31) |
            (@as(word, @intFromBool(unsigned_out.output == 0)) << 30) |
            (@as(word, @intFromBool(unsigned_out.carry)) << 29) |
            0x1f;
        if (unsigned_hi != case.um_lo or unsigned_lo != case.um_hi or unsigned_psr != case.um_psr) {
            std.debug.print("unsigned mismatch {s}: got {x:0>8}:{x:0>8} psr={x:0>8} expected {x:0>8}:{x:0>8} psr={x:0>8}\n", .{ case.name, unsigned_hi, unsigned_lo, unsigned_psr, case.um_lo, case.um_hi, case.um_psr });
            return error.TestExpectedEqual;
        }
    }
}
