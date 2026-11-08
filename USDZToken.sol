
  // SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ZCrypto V6：不可转账的内部筹码。
// 用户私密余额由 USDZVault 管理，Token 只记录筹码总供应量。
// 不使用 Proxy，不设置 OWNER，Vault 地址部署后不可更改。

contract USDZToken {
    string public constant name = "USDZ";
    string public constant symbol = "USDZ";
    uint8 public constant decimals = 18;

    address public immutable vault;                     // 唯一授权的资金合约
    uint256 public totalSupply;                         // USDZ 总供应量
    mapping(address => uint256) public balanceOf;        // 正常情况下只有 Vault 持有余额

    event Transfer(address indexed from, address indexed to, uint256 value);

    error ZeroAddress();
    error OnlyVault();
    error TransfersDisabled();
    error InsufficientBalance();

    // 初始化 Vault 地址，部署后永久固定。
    constructor(address vault_) {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    // 铸造筹码：只能由 Vault 调用，USDZ 直接进入 Vault。
    function mint(uint256 amount) external onlyVault {
        totalSupply += amount;
        balanceOf[vault] += amount;
        emit Transfer(address(0), vault, amount);
    }

    // 销毁筹码：只能由 Vault 调用。
    function burn(uint256 amount) external onlyVault {
        if (balanceOf[vault] < amount) revert InsufficientBalance();
        balanceOf[vault] -= amount;
        totalSupply -= amount;
        emit Transfer(vault, address(0), amount);
    }

    // 禁止用户转账。
    function transfer(address, uint256) external pure returns (bool) {
        revert TransfersDisabled();
    }

    // 禁止用户授权第三方操作筹码。
    function approve(address, uint256) external pure returns (bool) {
        revert TransfersDisabled();
    }

    // 禁止第三方转账。
    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert TransfersDisabled();
    }

    // 永远不存在 ERC-20 授权额度。
    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}
