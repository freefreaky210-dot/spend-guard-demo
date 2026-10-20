// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHook, IERC20, MODULE_TYPE_HOOK} from "./interfaces/IERC7579Module.sol";

/// @title SpendGuardHook
/// @notice ERC-7579 hook module (module type 4) that puts a leash on a smart account:
///         every execution is checked, before it runs, against
///           1. a target allowlist, and
///           2. a daily spending cap.
///         The cap counts native value AND the amount of any ERC20 `transfer`
///         call, so a session key / agent cannot drain the account by splitting
///         value across native sends and token transfers inside one day.
/// @dev    Demo build (clean-room). The calling smart account is msg.sender in
///         onInstall / preCheck / postCheck, per the ERC-7579 hook spec.
///         DEMO SIMPLIFICATION: the account passes preCheck a normalized payload
///         abi.encode(target, callData) instead of raw account calldata. A
///         production integration decodes the account's execute() calldata or
///         the UserOperation instead — the enforcement logic is unchanged.
contract SpendGuardHook is IHook {
    struct AccountConfig {
        bool initialized;
        uint256 dailyLimit;
        uint48 currentDay;
        uint256 spentToday;
        address[] targetList;
        mapping(address => bool) allowedTargets;
    }

    mapping(address => AccountConfig) internal _config;

    event Installed(address indexed account, uint256 dailyLimit, uint256 targetCount);
    event Uninstalled(address indexed account);
    event DailyLimitUpdated(address indexed account, uint256 newLimit);
    event TargetUpdated(address indexed account, address indexed target, bool allowed);
    event SpendChecked(address indexed account, address indexed target, uint256 spend, uint256 spentToday);

    error NotInitialized(address account);
    error AlreadyInitialized(address account);
    error InvalidConfig();
    error TargetNotAllowed(address target);
    error DailyLimitExceeded(uint256 spend, uint256 remaining);

    // ---------------------------------------------------------------
    // ERC-7579 module lifecycle
    // ---------------------------------------------------------------

    /// @param data abi.encode(uint256 dailyLimit, address[] initialTargets)
    function onInstall(bytes calldata data) external {
        address account = msg.sender;
        AccountConfig storage cfg = _config[account];
        if (cfg.initialized) revert AlreadyInitialized(account);

        (uint256 dailyLimit, address[] memory targets) = abi.decode(data, (uint256, address[]));
        if (dailyLimit == 0) revert InvalidConfig();

        cfg.initialized = true;
        cfg.dailyLimit = dailyLimit;
        cfg.currentDay = _today();
        cfg.spentToday = 0;
        for (uint256 i = 0; i < targets.length; i++) {
            if (!cfg.allowedTargets[targets[i]]) {
                cfg.allowedTargets[targets[i]] = true;
                cfg.targetList.push(targets[i]);
            }
        }
        emit Installed(account, dailyLimit, targets.length);
    }

    function onUninstall(bytes calldata) external {
        address account = msg.sender;
        AccountConfig storage cfg = _config[account];
        if (!cfg.initialized) revert NotInitialized(account);
        for (uint256 i = 0; i < cfg.targetList.length; i++) {
            delete cfg.allowedTargets[cfg.targetList[i]];
        }
        delete cfg.targetList;
        cfg.initialized = false;
        cfg.dailyLimit = 0;
        cfg.spentToday = 0;
        emit Uninstalled(account);
    }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_HOOK;
    }

    function isInitialized(address smartAccount) external view returns (bool) {
        return _config[smartAccount].initialized;
    }

    // ---------------------------------------------------------------
    // Hook checks — called by the smart account around every execution
    // ---------------------------------------------------------------

    /// @param msgData DEMO payload: abi.encode(address target, bytes callData)
    function preCheck(address, uint256 msgValue, bytes calldata msgData) external returns (bytes memory hookData) {
        address account = msg.sender;
        AccountConfig storage cfg = _config[account];
        if (!cfg.initialized) revert NotInitialized(account);

        (address target, bytes memory callData) = abi.decode(msgData, (address, bytes));
        if (!cfg.allowedTargets[target]) revert TargetNotAllowed(target);

        uint256 spend = msgValue + _erc20TransferAmount(callData);

        uint48 today = _today();
        if (today != cfg.currentDay) {
            cfg.currentDay = today;
            cfg.spentToday = 0;
        }
        if (cfg.spentToday + spend > cfg.dailyLimit) {
            revert DailyLimitExceeded(spend, cfg.dailyLimit - cfg.spentToday);
        }
        cfg.spentToday += spend;

        emit SpendChecked(account, target, spend, cfg.spentToday);
        return abi.encode(account, spend);
    }

    function postCheck(bytes calldata) external pure returns (bool success) {
        return true;
    }

    // ---------------------------------------------------------------
    // Account-managed configuration (msg.sender = the account)
    // ---------------------------------------------------------------

    function updateDailyLimit(uint256 newLimit) external {
        AccountConfig storage cfg = _config[msg.sender];
        if (!cfg.initialized) revert NotInitialized(msg.sender);
        if (newLimit == 0) revert InvalidConfig();
        cfg.dailyLimit = newLimit;
        emit DailyLimitUpdated(msg.sender, newLimit);
    }

    function updateTarget(address target, bool allowed) external {
        AccountConfig storage cfg = _config[msg.sender];
        if (!cfg.initialized) revert NotInitialized(msg.sender);
        if (allowed && !cfg.allowedTargets[target]) {
            cfg.targetList.push(target);
        }
        cfg.allowedTargets[target] = allowed;
        emit TargetUpdated(msg.sender, target, allowed);
    }

    // ---------------------------------------------------------------
    // Views (demo frontends, tests, judges)
    // ---------------------------------------------------------------

    function getStatus(address account)
        external
        view
        returns (bool initialized, uint256 dailyLimit, uint256 spentToday, uint256 remainingToday)
    {
        AccountConfig storage cfg = _config[account];
        initialized = cfg.initialized;
        dailyLimit = cfg.dailyLimit;
        spentToday = (_today() == cfg.currentDay) ? cfg.spentToday : 0;
        remainingToday = dailyLimit > spentToday ? dailyLimit - spentToday : 0;
    }

    function isTargetAllowed(address account, address target) external view returns (bool) {
        return _config[account].allowedTargets[target];
    }

    // ---------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------

    function _today() internal view returns (uint48) {
        return uint48(block.timestamp / 1 days);
    }

    /// @dev If callData is an ERC20 transfer(address,uint256), return its amount; else 0.
    function _erc20TransferAmount(bytes memory callData) internal pure returns (uint256 amount) {
        if (callData.length < 68) return 0;
        bytes4 selector;
        assembly {
            selector := mload(add(callData, 0x20))
        }
        if (selector != IERC20.transfer.selector) return 0;
        assembly {
            // memory layout: [len][selector 4B][arg0 32B][arg1 32B]
            amount := mload(add(callData, 0x44))
        }
    }
}
