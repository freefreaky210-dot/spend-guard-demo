// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHook} from "./interfaces/IERC7579Module.sol";

/// @title MockSmartAccount
/// @notice Minimal stand-in for an ERC-7579 smart account, just enough to
///         demonstrate hook enforcement: every executeGuarded() call is routed
///         through the installed hook's preCheck/postCheck, exactly the way a
///         real 7579 account invokes its hook module. It deliberately passes
///         the hook a normalized payload abi.encode(target, callData) — see
///         SpendGuardHook's notes on the production difference.
/// @dev NOT a production account. No EntryPoint, no validation logic, no
///      signature checks. Demo only.
contract MockSmartAccount {
    address public owner;
    IHook public hook;

    event Executed(address indexed target, uint256 value, bytes data);
    event HookSet(address indexed hook);

    error NotOwner();
    error HookRejectedPostCheck();
    error ExecutionFailed(bytes returnData);

    constructor(address _owner) payable {
        owner = _owner;
    }

    function setHook(address _hook) external {
        if (msg.sender != owner) revert NotOwner();
        hook = IHook(_hook);
        emit HookSet(_hook);
    }

    function executeGuarded(address target, uint256 value, bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != owner) revert NotOwner();

        bytes memory hookData;
        if (address(hook) != address(0)) {
            hookData = hook.preCheck(msg.sender, value, abi.encode(target, data));
        }

        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) revert ExecutionFailed(ret);

        if (address(hook) != address(0)) {
            if (!hook.postCheck(hookData)) revert HookRejectedPostCheck();
        }

        emit Executed(target, value, data);
        return ret;
    }

    receive() external payable {}
}
