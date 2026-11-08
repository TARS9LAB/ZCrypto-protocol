// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Papertrade PriceOracle 逆向重建版，并非官方原始源码。
// 只重建核心读取逻辑，省略 Proxy、OWNER、初始化、其他价格接口及批量读取。

contract PriceOracleReadReconstruction {

    // ==================== 1. 读取 HyperCore BBO ====================
    // asset：Hyperliquid 资产编号，例如某个 BTC 永续合约的资产 ID。
    // bid：最高买价（买一价）
    // ask：最低卖价（卖一价）
    function getBBO(uint32 asset) public view returns (uint64 bid, uint64 ask) {

        // 调用 HyperEVM 的 0x080e 预编译地址，读取 HyperCore 价格数据。
        // staticcall：只读调用，不允许修改链上状态。
        // abi.encode(asset)：把资产编号编码成调用参数。
        (bool ok, bytes memory out) = address(0x080e).staticcall(abi.encode(asset));

        // 调用必须成功，且至少返回 64 字节。
        require(ok && out.length >= 64, "BBO read failed");

        // 将返回数据解析成最高买价 bid、最低卖价 ask。
        (bid, ask) = abi.decode(out, (uint64, uint64));
    }

    // ==================== 2. 计算交易执行价格 ====================
    // 根据 BBO 计算中间价格：(bid + ask) / 2。
    // 函数输入签名经逆向确认，但原始返回类型宽度尚未完全确认。
    function getExecutionPrice(uint32 asset) external view returns (uint64) {

        // 读取最高买价和最低卖价。
        (uint64 bid, uint64 ask) = getBBO(asset);

        // 买一价、卖一价不能为 0。
        require(bid != 0 && ask != 0, "BBO unavailable");

        // 正常情况下买一价不能高于卖一价。
        require(bid <= ask, "BBO crossed");

        // 计算中间价格。先转换 uint256，防止 uint64 加法溢出。
        uint64 p = uint64((uint256(bid) + uint256(ask)) / 2);

        // 执行价格不能为 0。
        require(p != 0, "Execution price is zero");

        return p;
    }
}
