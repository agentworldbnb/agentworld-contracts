// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
/// @title Agent World deterministic 3v3 battle (DRAFT, unaudited)
/// @notice Pure integer simulation shared 1:1 with the web replay (replay/battlesim.js). Same inputs (6 character
/// indexes, 6 gear bps, VRF seed) => same winner on-chain and in the browser. Stats table = battle_ui/roster.js
/// order (2026-10-29: official hp/atk x0.49 => ~1.9x Genesis; base robots r01..r20 hp/atk normalised to equal N-tier power ~350 so the frame tier decides power): 0..9 official heroes o01..o10, 10..46 the 37 base characters. Each entry = hp,atk,def,spd (uint16 BE).
library BattleSim {
    uint256 internal constant N_CHARS = 47;
    uint256 internal constant MAX_ROUNDS = 30;
    uint256 internal constant EMPTY = 255; // empty slot marker (teams of 1-3)
    bytes internal constant STATS = hex"0b2c01a2011800af0c760197012c00a20a6601b3010900be0bd1019d012700aa0a8701a8010e00a80a5b01b8010600b60c080192011d00a10abe01ad010c00b20c3f0195013600a30aa801a4010a00ba03f30043008c002802ee006c0046005f029e0073005a002d03e90053003c00550343005a006400320238008900550050022d0096003c006402e1005a0096001902cd00730041005a024f008900460046049c003600aa0014027400810046006e0308005e006e0028036a005a0050004b0302005b0082003202a8006c006e003702df0067005f0041026c0081004b0069039b0053005a003c02bb005d00a0005a057800f000c8006e0546010400b400640514009600aa007806a4012c00be00960708012200c8008c047e00af00a50046041a00a0008c004b03d400c8005f0082051400be00aa005f03e800780096003c0384005a0064007303e800b9006e0078044c00c80078003c047e006e00aa005505dc00e600a00064079e014000f0008c09600168010400a0";

    /// SIGNATURE SKILLS (2026-10-30, on-chain): 2 bytes per character = kind, param. Fired on every 3rd action (not an ult turn).
    /// kinds: 0 SPLASH 125%+62% | 1 AOE p% every foe | 2 SNIPE p% target | 3 PIERCE p% target ignoring DEF | 4 ASSASSIN p% target, sure crit
    /// 5 HEAL 60% hit + every living ally heals p% max HP | 6 SHIELD 60% hit + every living ally gains a p% max-HP shield (shield <= 50% max)
    /// 7 WEAKEN 120% hit + target ATK -p% (once per unit) | 8 SLOW 100% hit + every living foe SPD -p% (once per unit)
    /// 9 RALLY 100% hit + every living ally ATK +p% (once per unit). Table = agent/skills.json (roster order).
    bytes internal constant SKILLS = hex"090f060c0396060f049602d2050c0714060a050f060f02b4014b050802b402d2048c014607190819060f038c02b4090f081e02be090c0146050a0150015503b4050f015a091402c8081e0719014b02b4050a090f03aa060f015501640514";
    struct U { uint256 hp; uint256 max; uint256 atk; uint256 def; uint256 spd; uint256 en; uint256 turns; uint256 dmg; bool sv; uint256 sh; uint256 fx; uint256 sk; uint256 sp; uint256 s4; uint256 ur; }
    /// GEAR v2 (2026-10-30). gearBps bit 32 = Sovereign flag, bits 33-35 = 4-piece set (0 none, 1 Riftwalker, 2 Starcore
    /// Hunter, 3 Singularity Siege, 4 Psionic Nexus), bits 36-38 = UR weapon passive (same ids). Outside the +20% cap:
    /// 4pc: 1 crit x1.65 (not 1.6) | 2 first own action dmg x1.05 | 3 heal 1.2% of real dmg dealt | 4 opening shield 0.8% max HP.
    /// UR (after a NORMAL attack only, roll = (keccak(seed, nonce of that attack) >> 24) % 100, no extra VRF):
    /// 1 Rift Echo 8%: +30% hit same target | 2 Plasma Pierce: normal attack ignores 8% DEF | 3 Gravity Tide 10%: 40% splash (exact-sim tuned from 20%)
    /// on another living foe | 4 Resonant Regen 10%: heal self 2% max HP. Extra hits never trigger passives (no chains).
    function skillOf(uint256 c) internal pure returns (uint256 kind, uint256 p) { require(c < N_CHARS, "char"); bytes memory s = SKILLS; kind = uint8(s[c * 2]); p = uint8(s[c * 2 + 1]); }

    function stats(uint256 c) internal pure returns (uint256 hp, uint256 atk, uint256 def, uint256 spd) {
        require(c < N_CHARS, "char");
        bytes memory s = STATS; uint256 o = c * 8;
        hp = uint256(uint8(s[o])) << 8 | uint8(s[o + 1]); atk = uint256(uint8(s[o + 2])) << 8 | uint8(s[o + 3]);
        def = uint256(uint8(s[o + 4])) << 8 | uint8(s[o + 5]); spd = uint256(uint8(s[o + 6])) << 8 | uint8(s[o + 7]);
    }

    /// @notice Deployed (linked) entry point used by AgentWorldArena so the battle code lives in the library, keeping the
    /// arena under the 24 KB contract-size limit. Identical to run().
    function runLinked(uint256[6] memory chars, uint256[6] memory gearBps, uint256 seed) public pure returns (uint8, uint256, uint256) {
        return run(chars, gearBps, seed);
    }
    /// @return winner 0 = team A, 1 = team B. @return rounds last round played. @return actions number of actions.
    function run(uint256[6] memory chars, uint256[6] memory gearBps, uint256 seed)
        internal pure returns (uint8 winner, uint256 rounds, uint256 actions)
    {
        U[6] memory u;
        for (uint256 i; i < 6; i++) {
            if (chars[i] == EMPTY) continue; // empty slot (1- or 2-card team): starts dead
            (uint256 hp, uint256 atk, uint256 def, uint256 spd) = stats(chars[i]);
            uint256 gb = gearBps[i] & 0xffffffff; hp = hp * (10_000 + gb) / 10_000; atk = atk * (10_000 + gb) / 10_000;
            bool sv = gearBps[i] >> 32 & 1 != 0; if (sv) { def *= 2; spd *= 2; } // Sovereign Set flag: +100% DEF & SPD
            u[i].hp = hp; u[i].max = hp; u[i].atk = atk; u[i].def = def; u[i].spd = spd; u[i].en = 30; u[i].sv = sv;
            u[i].s4 = gearBps[i] >> 33 & 7; u[i].ur = gearBps[i] >> 36 & 7;
            if (u[i].s4 == 4) u[i].sh = hp * 8 / 1000; // Hive Barrier: opening shield 0.8% max HP
            (u[i].sk, u[i].sp) = skillOf(chars[i]);
        }
        uint256 nonce; bool ko;
        for (rounds = 1; rounds <= MAX_ROUNDS && !ko; rounds++) {
            uint256[6] memory ord; uint256 n;
            for (uint256 i; i < 6; i++) if (u[i].hp > 0) { ord[n++] = i; }
            for (uint256 i = 1; i < n; i++) { // insertion sort: spd desc, then index asc (A before B, slot asc)
                uint256 x = ord[i]; uint256 j = i;
                while (j > 0 && u[ord[j - 1]].spd < u[x].spd) { ord[j] = ord[j - 1]; j--; }
                ord[j] = x;
            }
            for (uint256 q; q < n; q++) {
                uint256 a = ord[q]; if (u[a].hp == 0) continue;
                if (!_alive(u, a < 3 ? 3 : 0)) break;
                actions++; nonce = _act(u, a, seed, nonce);
                if (!_alive(u, 0) || !_alive(u, 3)) { ko = true; break; }
            }
        }
        rounds--;
        winner = ko ? (_alive(u, 0) ? 0 : 1) : _judge(u, seed);
    }

    function _act(U[6] memory u, uint256 a, uint256 seed, uint256 nonce) private pure returns (uint256) {
        uint256 foe = a < 3 ? 3 : 0;
        u[a].turns++;
        uint256 t = _lowest(u, foe);
        if (u[a].en >= 100) { // ult: every alive foe, 150%; Sovereign Set => "Sovereign Crescent" 280% + guaranteed crit
            bool sv = u[a].sv;
            for (uint256 k = foe; k < foe + 3; k++) if (u[k].hp > 0) nonce = _hit(u, a, k, sv ? 280 : 150, seed, nonce, sv ? 1 : 0);
            u[a].en = 0;
            return nonce;
        }
        if (u[a].turns % 3 == 0) nonce = _skill(u, a, t, foe, seed, nonce);
        else {
            uint256 ur = u[a].ur; uint256 rr = ur == 0 ? 100 : (uint256(keccak256(abi.encode(seed, nonce))) >> 24) % 100;
            nonce = _hit(u, a, t, 100, seed, nonce, ur == 2 ? 4 : 0);
            if (ur == 1 && rr < 8 && u[t].hp > 0) nonce = _hit(u, a, t, 30, seed, nonce, 0); // Rift Echo
            else if (ur == 3 && rr < 10) { for (uint256 k = foe; k < foe + 3; k++) if (k != t && u[k].hp > 0) { nonce = _hit(u, a, k, 40, seed, nonce, 0); break; } } // Gravity Tide
            else if (ur == 4 && rr < 10) { uint256 h = u[a].hp + u[a].max * 2 / 100; u[a].hp = h > u[a].max ? u[a].max : h; } // Resonant Regen
        }
        u[a].en = u[a].en + 34 > 100 ? 100 : u[a].en + 34;
        return nonce;
    }

    function _skill(U[6] memory u, uint256 a, uint256 t, uint256 foe, uint256 seed, uint256 nonce) private pure returns (uint256) {
        uint256 kd = u[a].sk; uint256 p = u[a].sp; uint256 own = a < 3 ? 0 : 3;
        if (kd == 0) {
            nonce = _hit(u, a, t, 125, seed, nonce, 0);
            for (uint256 k = foe; k < foe + 3; k++) if (k != t && u[k].hp > 0) { nonce = _hit(u, a, k, 62, seed, nonce, 0); break; }
        } else if (kd == 1) { for (uint256 k = foe; k < foe + 3; k++) if (u[k].hp > 0) nonce = _hit(u, a, k, p, seed, nonce, 0); }
        else if (kd == 2) nonce = _hit(u, a, t, p, seed, nonce, 0);
        else if (kd == 3) nonce = _hit(u, a, t, p, seed, nonce, 2);
        else if (kd == 4) nonce = _hit(u, a, t, p, seed, nonce, 1);
        else if (kd == 5) { nonce = _hit(u, a, t, 60, seed, nonce, 0);
            for (uint256 k = own; k < own + 3; k++) if (u[k].hp > 0) { uint256 h = u[k].hp + u[k].max * p / 100; u[k].hp = h > u[k].max ? u[k].max : h; } }
        else if (kd == 6) { nonce = _hit(u, a, t, 60, seed, nonce, 0);
            for (uint256 k = own; k < own + 3; k++) if (u[k].hp > 0) { uint256 h = u[k].sh + u[k].max * p / 100; u[k].sh = h > u[k].max / 2 ? u[k].max / 2 : h; } }
        else if (kd == 7) { nonce = _hit(u, a, t, 120, seed, nonce, 0); if (u[t].fx & 1 == 0) { u[t].fx |= 1; u[t].atk = u[t].atk * (100 - p) / 100; } }
        else if (kd == 8) { nonce = _hit(u, a, t, 100, seed, nonce, 0);
            for (uint256 k = foe; k < foe + 3; k++) if (u[k].hp > 0 && u[k].fx & 2 == 0) { u[k].fx |= 2; u[k].spd = u[k].spd * (100 - p) / 100; } }
        else { nonce = _hit(u, a, t, 100, seed, nonce, 0);
            for (uint256 k = own; k < own + 3; k++) if (u[k].hp > 0 && u[k].fx & 4 == 0) { u[k].fx |= 4; u[k].atk = u[k].atk * (100 + p) / 100; } }
        return nonce;
    }

    /// Timeout: higher remaining HP ratio, then more damage dealt, then a seed coin flip (no draws).
    function _judge(U[6] memory u, uint256 seed) private pure returns (uint8) {
        uint256 hA = u[0].hp + u[1].hp + u[2].hp; uint256 mA = u[0].max + u[1].max + u[2].max;
        uint256 hB = u[3].hp + u[4].hp + u[5].hp; uint256 mB = u[3].max + u[4].max + u[5].max;
        if (hA * mB != hB * mA) return hA * mB > hB * mA ? 0 : 1;
        uint256 dA = u[0].dmg + u[1].dmg + u[2].dmg; uint256 dB = u[3].dmg + u[4].dmg + u[5].dmg;
        if (dA != dB) return dA > dB ? 0 : 1;
        return uint8(uint256(keccak256(abi.encode(seed, type(uint256).max))) & 1);
    }

    function _alive(U[6] memory u, uint256 from) private pure returns (bool) { return u[from].hp > 0 || u[from + 1].hp > 0 || u[from + 2].hp > 0; }
    function _lowest(U[6] memory u, uint256 from) private pure returns (uint256 t) {
        t = 6; for (uint256 k = from; k < from + 3; k++) if (u[k].hp > 0 && (t == 6 || u[k].hp < u[t].hp)) t = k;
    }
    /// dmg = atk * mult% * roll(90..110)% * 300/(300+def) (def = 0 for PIERCE); crit 15% (always for Sovereign Crescent /
    /// ASSASSIN) => x1.6; min 1; a shield absorbs first. Rolls = keccak256(seed, nonce). mode bit0 = sure crit, bit1 = ignore DEF.
    function _hit(U[6] memory u, uint256 a, uint256 t, uint256 mult, uint256 seed, uint256 nonce, uint256 mode) private pure returns (uint256) {
        uint256 r = uint256(keccak256(abi.encode(seed, nonce)));
        uint256 df = mode & 2 != 0 ? 0 : u[t].def; if (mode & 4 != 0) df = df * 92 / 100; // bit2 = Plasma Pierce (-8% DEF)
        uint256 d = u[a].atk * mult * (90 + r % 21) * 300 / (10_000 * (300 + df));
        if (mode & 1 != 0 || (r >> 16) % 100 < 15) d = d * (u[a].s4 == 1 ? 165 : 160) / 100; // Phase Edge: crit x1.65
        if (u[a].s4 == 2 && u[a].turns == 1) d = d * 105 / 100; // First Lock: first own action x1.05
        if (d == 0) d = 1;
        if (u[t].sh > 0) { uint256 ab = d < u[t].sh ? d : u[t].sh; u[t].sh -= ab; d -= ab; }
        uint256 real = d < u[t].hp ? d : u[t].hp; u[t].hp -= real; u[a].dmg += real; // d may be 0 after a shield
        if (u[a].s4 == 3) { uint256 h = u[a].hp + real * 12 / 1000; u[a].hp = h > u[a].max ? u[a].max : h; } // Accretion: heal 1.2% of real dmg
        u[t].en = u[t].en + 12 > 100 ? 100 : u[t].en + 12;
        return nonce + 1;
    }
}
