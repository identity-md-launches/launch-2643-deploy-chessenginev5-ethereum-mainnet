// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Strength} from "../src/Strength.sol";

contract StrengthHarness {
    function fromShare(uint256 paid, uint256 depth) external pure returns (uint16) {
        return Strength.fromShare(paid, depth);
    }
}

/// Direct coverage of the shipped strength curve, independent of any hook.
/// The overflow cases characterize the unresolved audit finding; see ADAPTATION.md.
contract StrengthTest is Test {
    uint256 internal constant MAX_SAFE_PAID = type(uint256).max / 100_000;
    StrengthHarness internal curve = new StrengthHarness();

    function test_decidedPoints() public pure {
        uint256 depth = 1e9;
        assertEq(Strength.fromShare(1_000, depth), 0, "below the floor");
        assertEq(Strength.fromShare(10_000, depth), 0, "0.001% share");
        // The interpolated logarithm approximates each nominal point within one percentage point.
        assertApproxEqAbs(Strength.fromShare(100_000, depth), 3_000, 100, "0.01% share");
        assertApproxEqAbs(Strength.fromShare(1_000_000, depth), 6_000, 100, "0.1% share");
        assertApproxEqAbs(Strength.fromShare(10_000_000, depth), 9_000, 100, "1% share");
        assertEq(Strength.fromShare(100_000_000, depth), 9_000, "above the cap");
        assertEq(Strength.fromShare(depth, depth), 9_000, "entire depth");
        assertEq(Strength.fromShare(depth * 10, depth), 9_000, "more than the depth");
    }

    function test_zeroInputs() public pure {
        assertEq(Strength.fromShare(0, 0), 0);
        assertEq(Strength.fromShare(0, type(uint256).max), 0);
        assertEq(Strength.fromShare(type(uint256).max, 0), 0);
    }

    function testFuzz_boundedAndMonotonic(uint256 paid, uint256 more, uint256 depth) public pure {
        paid = bound(paid, 0, MAX_SAFE_PAID);
        more = bound(more, paid, MAX_SAFE_PAID);
        uint256 low = Strength.fromShare(paid, depth);
        uint256 high = Strength.fromShare(more, depth);
        assertLe(low, high, "paying more cannot reduce strength");
        assertLe(high, 9_000, "strength remains capped");
    }

    function testFuzz_depthMonotonic(uint256 paid, uint256 depth, uint256 deeper) public pure {
        paid = bound(paid, 0, MAX_SAFE_PAID);
        depth = bound(depth, 1, type(uint256).max);
        deeper = bound(deeper, depth, type(uint256).max);
        assertLe(Strength.fromShare(paid, deeper), Strength.fromShare(paid, depth), "more depth reduces share");
    }

    function testFuzz_tenfoldIsAboutThirtyPoints(uint128 rawPaid, uint128 rawDepth) public pure {
        uint256 depth = bound(uint256(rawDepth), 1_000_000, type(uint128).max);
        // Keep both shares between the floor and nominal cap, with no multiplication overflow.
        uint256 paid = bound(uint256(rawPaid), (depth + 99_999) / 100_000, depth / 1_000);
        uint256 before = Strength.fromShare(paid, depth);
        uint256 afterTenfold = Strength.fromShare(paid * 10, depth);
        assertGe(afterTenfold, before);
        assertApproxEqAbs(afterTenfold - before, 3_000, 100);
    }

    function test_knownOverflowAtMultiplicationBoundary() public {
        assertEq(curve.fromShare(MAX_SAFE_PAID, 1), 9_000, "last safe paid can reach the cap");
        assertEq(curve.fromShare(MAX_SAFE_PAID, type(uint256).max), 0, "last safe paid near the floor");
        // Audit 8116943f: this is the existing panic, not a fix or an intended input restriction.
        // Production sources are preserved for the engine-only launch, which does not call Strength.
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        curve.fromShare(MAX_SAFE_PAID + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        curve.fromShare(type(uint256).max, 1);
    }

    function testFuzz_knownOverflowAboveMultiplicationBoundary(uint256 paid, uint256 depth) public {
        paid = bound(paid, MAX_SAFE_PAID + 1, type(uint256).max);
        depth = bound(depth, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        curve.fromShare(paid, depth);
    }
}
