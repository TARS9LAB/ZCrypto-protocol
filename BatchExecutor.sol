// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Papertrade BatchExecutor 逆向重建版，并非官方源码。
// 部分字段名称和行为由分析人员推断，不能直接用于生产部署。
// Storage、初始化、事件和部分内部函数实现均未包含。

abstract contract BatchExecutorReconstruction {

    // ==================== 1. 单个调用任务 ====================
    struct Call {
        address target;       // 目标合约：Exchange、SessionKeyManager、PaperStaking
        bytes data;           // ABI 编码的调用数据，前4字节是函数选择器
        bool allowFailure;    // true：允许单项失败；false：失败时回滚整个批次
        bytes32 failureGroup; // 失败关联组，同组前置任务失败则跳过后续任务（推断）
        bytes32 itemId;       // 单个任务标识，用于关联执行结果（推断）
    }

    // ==================== 2. 状态变量 ====================
    mapping(address => bool) internal authorizedRelayers; // Relayer 白名单
    address internal exchange;          // Exchange 核心交易合约
    address internal sessionKeyManager; // Session Key 管理合约
    address internal paperStaking;      // PAPER 质押合约

    // ==================== 3. 批量执行入口 ====================
    // 只有授权 Relayer 可以调用，execute() 对应归档选择器 0x251fb27d。
    function execute(Call[] calldata calls) external {
        require(authorizedRelayers[msg.sender], "reconstructed unauthorized");

        bytes32[] memory failedGroups = new bytes32[](calls.length); // 记录失败关联组
        uint256 count;                            // 已记录的失败组数量
        bytes32 batchId = keccak256(msg.data);    // 完整 calldata 哈希，用于关联批次事件

        // 逐个执行 Call
        for (uint256 i; i < calls.length; ++i) {
            Call calldata c = calls[i];

            // 同组之前已有失败任务，则跳过当前任务
            if (c.failureGroup != bytes32(0) && contains(failedGroups, count, c.failureGroup)) {
                recordSkipped(batchId, i, c.itemId, c.failureGroup);
                continue;
            }

            bytes memory reason; // 保存返回数据或失败原因
            bool ok;             // 目标合约调用是否成功

            // calldata 少于4字节，无法提取正常函数选择器
            if (c.data.length < 4) {
                reason = abi.encodeWithSelector(bytes4(0x635a68e0), c.data.length);
            }
            // 目标合约或函数不在白名单，拒绝执行
            else if (!allowed(c.target, bytes4(c.data[:4]))) {
                reason = bytes("BatchExecutor: selector not allowed");
            }
            // 检查通过，执行目标合约函数
            else {
                (ok, reason) = c.target.call(c.data);
                // 普通 CALL，不是 delegatecall，也不发送 ETH
                // 目标合约看到的 msg.sender 是 BatchExecutor，而不是 Relayer
            }

            // 处理失败
            if (!ok) {
                if (!c.allowFailure) revertBatch(i, reason); // 不允许失败：预期回滚整笔交易
                if (c.failureGroup != bytes32(0)) failedGroups[count++] = c.failureGroup;
            }

            // 记录当前任务结果，无论成功还是允许的失败
            recordResult(batchId, i, c.itemId, ok, reason);
        }
        // 聚合统计及事件编码没有在此重建
    }

    // ==================== 4. 合约 + 函数白名单 ====================
    // Relayer 不能调用任意合约，只能调用这里允许的 target + selector。
    function allowed(address target, bytes4 s) internal view returns (bool) {
        // Exchange：允许3个函数
        if (target == exchange) return s == 0xec6783f0 || s == 0x2792e706 || s == 0x8d09f23f;

        // SessionKeyManager：允许1个函数
        if (target == sessionKeyManager) return s == 0x5f76a1d6;

        // PaperStaking：允许4个函数
        if (target == paperStaking) {
            return s == 0x83115825 || s == 0xfa2871b5 || s == 0x9c96d4a1 || s == 0xf0355460;
        }

        return false; // 其他合约或函数全部拒绝
    }

    // ==================== 5. 检查失败关联组 ====================
    // 线性搜索：判断失败组 x 是否已存在于数组 a 的前 n 项。
    function contains(bytes32[] memory a, uint256 n, bytes32 x) private pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (a[i] == x) return true;
        }
        return false;
    }

    // ==================== 6. 抽象函数 ====================
    // 以下函数具体实现未重建，预计用于事件记录和失败回滚。

    function recordSkipped(bytes32, uint256, bytes32, bytes32) internal virtual; // 记录跳过任务
    function recordResult(bytes32, uint256, bytes32, bool, bytes memory) internal virtual; // 记录执行结果
    function revertBatch(uint256, bytes memory) internal virtual; // 处理不可容忍的失败
}
