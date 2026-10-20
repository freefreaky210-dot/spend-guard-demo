// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ERC-7579 module type ids
uint256 constant MODULE_TYPE_VALIDATOR = 1;
uint256 constant MODULE_TYPE_EXECUTOR = 2;
uint256 constant MODULE_TYPE_FALLBACK = 3;
uint256 constant MODULE_TYPE_HOOK = 4;

/// @notice Base ERC-7579 module interface (per the ERC-7579 specification)
interface IModule {
    function onInstall(bytes calldata data) external;
    function onUninstall(bytes calldata data) external;
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
    function isInitialized(address smartAccount) external view returns (bool);
}

/// @notice ERC-7579 hook module interface.
/// @dev The smart account calls preCheck before executing and postCheck after.
///      In both calls, msg.sender is the smart account itself.
interface IHook is IModule {
    function preCheck(address msgSender, uint256 msgValue, bytes calldata msgData)
        external
        returns (bytes memory hookData);
    function postCheck(bytes calldata hookData) external returns (bool success);
}

/// @notice Minimal ERC20 surface used to recognize transfer calls
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
