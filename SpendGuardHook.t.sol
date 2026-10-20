// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SpendGuardHook} from "../src/SpendGuardHook.sol";
import {MockSmartAccount} from "../src/MockSmartAccount.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Minimal Foundry cheatcode surface — keeps this demo dependency-free
///         (no forge-std). The full suite still runs under plain `forge test`.
interface Vm {
    function prank(address msgSender) external;
    function expectRevert(bytes calldata revertData) external;
    function expectRevert() external;
    function warp(uint256 newTimestamp) external;
    function deal(address account, uint256 newBalance) external;
}

contract SpendGuardHookTest {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    SpendGuardHook internal hook;
    MockSmartAccount internal account;
    MockERC20 internal token;

    address internal owner = address(0xA11CE);
    address internal vendor = address(0xBEEF);
    address internal stranger = address(0xBAD);

    uint256 internal constant LIMIT = 1 ether; // doubles as token units in tests

    function setUp() public {
        hook = new SpendGuardHook();
        account = new MockSmartAccount(owner);
        token = new MockERC20();

        vm.deal(address(account), 10 ether);
        token.mint(address(account), 10 ether);

        address[] memory targets = new address[](2);
        targets[0] = vendor;
        targets[1] = address(token);

        // The account installs the hook (msg.sender = account)
        vm.prank(address(account));
        hook.onInstall(abi.encode(LIMIT, targets));

        vm.prank(owner);
        account.setHook(address(hook));
    }

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------

    function assertEq(uint256 a, uint256 b, string memory what) internal pure {
        require(a == b, string.concat("assertEq failed: ", what));
    }

    function assertTrue(bool c, string memory what) internal pure {
        require(c, string.concat("assertTrue failed: ", what));
    }

    function assertFalse(bool c, string memory what) internal pure {
        require(!c, string.concat("assertFalse failed: ", what));
    }

    // ---------------------------------------------------------------
    // lifecycle / metadata
    // ---------------------------------------------------------------

    function test_Install_state() public view {
        assertTrue(hook.isInitialized(address(account)), "initialized");
        assertTrue(hook.isModuleType(4), "is hook type");
        assertFalse(hook.isModuleType(1), "not validator type");
        (bool init, uint256 limit, uint256 spent, uint256 remaining) = hook.getStatus(address(account));
        assertTrue(init, "status init");
        assertEq(limit, LIMIT, "limit");
        assertEq(spent, 0, "spent starts at 0");
        assertEq(remaining, LIMIT, "remaining = limit");
        assertTrue(hook.isTargetAllowed(address(account), vendor), "vendor allowed");
        assertTrue(hook.isTargetAllowed(address(account), address(token)), "token allowed");
        assertFalse(hook.isTargetAllowed(address(account), stranger), "stranger not allowed");
    }

    function test_Install_twiceReverts() public {
        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(SpendGuardHook.AlreadyInitialized.selector, address(account)));
        hook.onInstall(abi.encode(LIMIT, new address[](0)));
    }

    // ---------------------------------------------------------------
    // enforcement
    // ---------------------------------------------------------------

    function test_NativeSpend_withinLimit() public {
        uint256 before_ = vendor.balance;
        vm.prank(owner);
        account.executeGuarded(vendor, 0.4 ether, "");
        assertEq(vendor.balance - before_, 0.4 ether, "vendor received");
        (, , uint256 spent, uint256 remaining) = hook.getStatus(address(account));
        assertEq(spent, 0.4 ether, "spent tracked");
        assertEq(remaining, 0.6 ether, "remaining reduced");
    }

    function test_NativeSpend_overLimitReverts() public {
        vm.prank(owner);
        account.executeGuarded(vendor, 0.7 ether, "");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SpendGuardHook.DailyLimitExceeded.selector, 0.4 ether, 0.3 ether));
        account.executeGuarded(vendor, 0.4 ether, "");
    }

    function test_TargetNotAllowedReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SpendGuardHook.TargetNotAllowed.selector, stranger));
        account.executeGuarded(stranger, 0.1 ether, "");
    }

    function test_Erc20Transfer_countsTowardLimit() public {
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", vendor, 0.6 ether);
        vm.prank(owner);
        account.executeGuarded(address(token), 0, data);
        assertEq(token.balanceOf(vendor), 0.6 ether, "vendor got tokens");
        (, , uint256 spent, ) = hook.getStatus(address(account));
        assertEq(spent, 0.6 ether, "token amount counted toward cap");

        // 0.6 already spent -> another 0.5 would breach the 1.0 cap
        bytes memory data2 = abi.encodeWithSignature("transfer(address,uint256)", vendor, 0.5 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SpendGuardHook.DailyLimitExceeded.selector, 0.5 ether, 0.4 ether));
        account.executeGuarded(address(token), 0, data2);
    }

    function test_MixedNativeAndToken_shareOneCap() public {
        vm.prank(owner);
        account.executeGuarded(vendor, 0.5 ether, "");
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", vendor, 0.5 ether);
        vm.prank(owner);
        account.executeGuarded(address(token), 0, data);
        (, , uint256 spent, uint256 remaining) = hook.getStatus(address(account));
        assertEq(spent, 1 ether, "combined spend hits cap exactly");
        assertEq(remaining, 0, "nothing left today");
    }

    function test_DailyWindow_resets() public {
        vm.prank(owner);
        account.executeGuarded(vendor, 0.9 ether, "");
        vm.warp(block.timestamp + 1 days + 1);
        (, , uint256 spent, uint256 remaining) = hook.getStatus(address(account));
        assertEq(spent, 0, "new day, spend reset in view");
        assertEq(remaining, LIMIT, "full budget back");
        vm.prank(owner);
        account.executeGuarded(vendor, 0.9 ether, "");
    }

    // ---------------------------------------------------------------
    // account-managed configuration
    // ---------------------------------------------------------------

    function test_AccountCanUpdateLimitAndTargets() public {
        vm.prank(address(account));
        hook.updateDailyLimit(2 ether);
        vm.prank(address(account));
        hook.updateTarget(stranger, true);
        assertTrue(hook.isTargetAllowed(address(account), stranger), "stranger now allowed");
        vm.prank(owner);
        account.executeGuarded(stranger, 1.5 ether, "");
    }

    function test_StrangerCannotConfigure() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SpendGuardHook.NotInitialized.selector, stranger));
        hook.updateDailyLimit(100 ether);
    }

    // ---------------------------------------------------------------
    // uninstall
    // ---------------------------------------------------------------

    function test_Uninstall_blocksAndReinstallWorks() public {
        vm.prank(address(account));
        hook.onUninstall("");
        assertFalse(hook.isInitialized(address(account)), "uninstalled");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SpendGuardHook.NotInitialized.selector, address(account)));
        account.executeGuarded(vendor, 0.1 ether, "");

        address[] memory targets = new address[](1);
        targets[0] = vendor;
        vm.prank(address(account));
        hook.onInstall(abi.encode(0.25 ether, targets));
        vm.prank(owner);
        account.executeGuarded(vendor, 0.2 ether, "");
    }
}
