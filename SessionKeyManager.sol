
  // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Papertrade SessionKeyManager 逆向重建版，并非官方原始源码。
// 保留恢复出的存储槽位置、签名验证、Nonce、Session Key 注册及撤销逻辑。
// 原合约使用 Proxy，本版本用 constructor 替代初始化器，仅供研究。
// 未知函数通过 fallback + selector 调用，不能直接作为生产合约部署。

contract SessionKeyManagerReconstruction {
    // ==================== 1. 状态变量 ====================
    uint16 private initializationFlags;                       // slot 0：初始化标志
    bytes32 public DOMAIN_SEPARATOR;                         // slot 1：存储的 EIP-712 Domain（本代码实际计算使用 domainSeparatorV4()）
    address public owner;                                    // slot 2：管理员地址
    address public authorizedCaller;                         // slot 3：允许消费 Intent Nonce 的业务合约

    // Session Key 记录：有效期 + Builder 手续费地址
    struct Session {
        uint64 expiry;       // Session Key 到期时间，Unix 时间戳
        address feeAddress;  // Builder / 手续费归属地址
    }

    mapping(address => mapping(address => Session)) public sessionKeys; // slot 4：主钱包 => Session Key => 授权信息
    mapping(address => uint256) public nonces;                          // slot 5：用户 Nonce 记录，保存已消费 Nonce 的高水位
    mapping(address => mapping(uint256 => uint256)) internal nonceBitmap; // slot 6：Nonce 位图，每256个Nonce占一个uint256
    mapping(address => bool) public authorizedSubmitters;               // slot 7：允许提交 Session Key 注册交易的地址

    // ==================== 2. EIP-712 签名类型 ====================
    // 主钱包签署注册授权时，必须包含 user、key、expiry、feeAddress、nonce、deadline。
    bytes32 private constant REGISTER_TYPEHASH =
        keccak256("RegisterSessionKey(address user,address key,uint64 expiry,address feeAddress,uint256 nonce,uint64 deadline)");

    // EIP-712 Domain：名称、版本、链ID、验证合约地址。
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // ==================== 3. 初始化 ====================
    // 本构造函数由逆向分析人员添加，不是恢复出来的原始 ABI。
    constructor(address initialOwner, address caller) {
        initializationFlags = 1;                // 标记已初始化
        owner = initialOwner;                   // 设置管理员
        authorizedCaller = caller;              // 设置授权业务合约
        DOMAIN_SEPARATOR = domainSeparatorV4(); // 保存当前 Domain
    }

    // ==================== 4. EIP-712 Domain ====================
    // 注意：verifyingContract 使用 authorizedCaller，而不是本合约地址。
    // "String" 和 "1" 是这份重建代码中使用的 Domain 名称与版本。
    // 如果 authorizedCaller 变化，动态计算的 Domain 也会变化。
    function domainSeparatorV4() public view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256("String"),
            keccak256("1"),
            block.chainid,
            authorizedCaller
        ));
    }

    // ==================== 5. 查询 Nonce 是否已使用 ====================
    // nonce >> 8：除以256，定位Bitmap存储字。
    // nonce & 255：取模256，定位该字内的具体Bit。
    function isNonceUsed(address user, uint256 nonce) public view returns (bool) {
        return nonceBitmap[user][nonce >> 8] & (uint256(1) << (nonce & 255)) != 0;
    }

    // ==================== 6. 消费 Nonce，防止重复执行 ====================
    // 所有注册和 Intent 消费都使用同一个用户的 nonceBitmap。
    function consume(address user, uint256 nonce) internal {
        uint256 word = nonce >> 8;                // 当前Nonce属于哪一个256位存储字
        uint256 bit = uint256(1) << (nonce & 255); // 当前Nonce对应的Bit
        if (nonceBitmap[user][word] & bit != 0) fail(0x756688fe); // 已使用则回滚
        nonceBitmap[user][word] |= bit;           // 标记该Nonce已使用
        if (nonce >= nonces[user]) nonces[user] = nonce + 1; // 更新高水位，不代表较小Nonce都已使用
    }

    // ==================== 7. 通过主钱包签名注册 Session Key ====================
    // 由白名单 Submitter 提交交易，但注册权限必须来自 user 主钱包签名。
    function registerSessionKeyBySig(
        address user, address key, uint64 expiry, address feeAddress,
        uint256 nonce, uint64 deadline, uint8 v, bytes32 r, bytes32 s
    ) external {
        if (!authorizedSubmitters[msg.sender]) fail(0x93b78c88); // 提交者不在白名单
        if (key == address(0)) fail(0x276f9a65);                  // Session Key 不能为零地址
        if (block.timestamp > deadline) fail(0xf87d9271);        // 注册授权已过期
        consume(user, nonce);                                     // 防重放；后续revert会回滚Nonce修改

        // 按照 EIP-712 格式计算注册授权的结构哈希。
        bytes32 structHash = keccak256(abi.encode(
            REGISTER_TYPEHASH, user, key, expiry, feeAddress, nonce, deadline
        ));

        // 恢复签名者地址，必须等于用户主钱包地址。
        address signer = recoverSigner(digest(structHash), v, r, s);
        if (signer == address(0) || signer != user) fail(0x8baa579f);

        // ==================== 8. 使用 Assembly 写入 Session Key ====================
        // sessionKeys 是双层 mapping，首先计算 user 对应的映射槽，再计算 key 的记录槽。
        bytes32 recordSlot = keccak256(abi.encode(
            key, keccak256(abi.encode(user, uint256(4)))
        ));

        // Session 数据被打包在同一个存储槽中：
        // 低64位存 expiry；接下来的160位存 feeAddress；高32位保留原值。
        // 这是逆向复现的存储写入行为，普通开发可直接使用 sessionKeys[user][key] 赋值。
        assembly {
            sstore(
                recordSlot,
                or(
                    and(sload(recordSlot), shl(224, 0xffffffff)),
                    or(expiry, shl(64, feeAddress))
                )
            )
        }

        // ==================== 9. 记录 Session Key 注册事件 ====================
        // 事件Topic由逆向得到，使用log3写入：事件签名Topic + user + key。
        bytes32 topic = 0x3cec0566535d67d6c92668517af0bf8a66cdc91d622dbb830fcc08e1bcf5d1df;
        bytes memory eventData = abi.encode(expiry, feeAddress);
        assembly { log3(add(eventData, 32), 64, topic, user, key) }
    }

    // ==================== 10. 用户主动撤销 Session Key ====================
    // msg.sender 就是主钱包用户，不能在这里指定其他人的 user。
    function revokeSessionKey(address key) external {
        // 计算 sessionKeys[msg.sender][key] 的实际存储槽。
        bytes32 recordSlot = keccak256(abi.encode(
            key, keccak256(abi.encode(msg.sender, uint256(4)))
        ));

        assembly { sstore(recordSlot, 0) } // 清空授权记录，expiry=0，立即失效

        // 记录撤销事件，Topic由逆向恢复。
        bytes32 topic = 0x744157ccffbd293a2e8644928cd7d23d650f869b88f72d7bfea8041b76ca6bec;
        assembly { log3(0, 0, topic, caller(), key) }
    }

    // ==================== 11. 消费用户交易 Intent ====================
    // 只能由 authorizedCaller 调用，不允许普通 Relayer 直接消费Nonce。
    // 注意：这里只检查调用者、截止时间和Nonce，不独立验证Session Key签名。
    function consumeIntent(address user, uint256 nonce, uint64 deadline) internal {
        if (msg.sender != authorizedCaller) fail(0x5c427cd9); // 必须是指定业务合约
        if (block.timestamp > deadline) fail(0xf87d9271);   // Intent 已过期
        consume(user, nonce);                                 // 消费Nonce，防止重复执行
    }

    // ==================== 12. 恢复并验证 Session Key ====================
    // structHash：由业务合约计算的EIP-712交易结构哈希。
    // v/r/s：Session Key 对该交易的签名。
    // 这里只检查签名者是否拥有未过期的Session授权，不检查金额、竞猜规则或资金。
    function recoverSession(
        address user, bytes32 structHash,
        uint8 v, bytes32 r, bytes32 s
    ) internal view returns (uint64 expiry) {
        address key = recoverSigner(digest(structHash), v, r, s); // 恢复Session Key地址
        expiry = sessionKeys[user][key].expiry;                   // 读取该用户对这把Key的授权
        if (expiry == 0) fail(0xc5045f22);                        // 不存在有效授权记录
        if (block.timestamp > expiry) fail(0xda0700a2);           // Session Key已过期
    }

    // ==================== 13. ECDSA 签名恢复 ====================
    // 检查v和s，限制高s签名，减少ECDSA签名可塑性。
    // 签名不合法时返回零地址，而不是直接回滚。
    function recoverSigner(bytes32 hash, uint8 v, bytes32 r, bytes32 s) public pure returns (address) {
        if (
            (v != 27 && v != 28) ||
            uint256(s) > 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0
        ) return address(0);
        return ecrecover(hash, v, r, s);
    }

    // ==================== 14. 计算最终EIP-712签名摘要 ====================
    // EIP-712最终摘要 = keccak256(0x1901 || DomainSeparator || StructHash)。
    function digest(bytes32 h) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparatorV4(), h));
    }

    // ==================== 15. OWNER管理授权提交者 ====================
    // 控制哪些地址可以转发 Session Key 注册请求。
    function setAuthorizedSubmitter(address who, bool yes) external {
        if (msg.sender != owner) fail(0x30cd7471);
        authorizedSubmitters[who] = yes; // true授权，false撤销
        // 管理事件在逆向代码中省略
    }

    // ==================== 16. OWNER设置业务调用合约 ====================
    // authorizedCaller拥有consumeIntent的调用权限。
    // 该地址也是动态EIP-712 Domain的verifyingContract。
    function setAuthorizedCaller(address who) external {
        if (msg.sender != owner) fail(0x30cd7471);
        authorizedCaller = who;
        // 管理事件在逆向代码中省略
    }

    // ==================== 17. 转移OWNER权限 ====================
    function transferOwnership(address who) external {
        if (msg.sender != owner) fail(0x30cd7471);
        owner = who;
        // 管理事件在逆向代码中省略
    }

    // ==================== 18. fallback：处理逆向恢复的未知函数 ====================
    // 原始函数名称未知，只恢复了函数selector和对应行为。
    fallback(bytes calldata input) external returns (bytes memory) {

        // selector 0xb002b9fa：消费指定用户Intent的Nonce。
        // 参数：(user, nonce, deadline)；内部验证authorizedCaller权限。
        if (msg.sig == 0xb002b9fa) {
            (address u, uint256 n, uint64 d) = abi.decode(
                input[4:], (address, uint256, uint64)
            );
            consumeIntent(u, n, d);
            return bytes("");
        }

        // selector 0x7f608253：根据签名恢复Session Key，并查询授权有效期。
        // 参数：(user, structHash, v, r, s)。
        // 注意：只返回expiry，不消费Nonce，也不执行交易。
        if (msg.sig == 0x7f608253) {
            (address u, bytes32 h, uint8 v, bytes32 r, bytes32 s) = abi.decode(
                input[4:], (address, bytes32, uint8, bytes32, bytes32)
            );
            return abi.encode(recoverSession(u, h, v, r, s));
        }

        revert("unreconstructed selector"); // 未恢复的函数选择器，直接拒绝
    }

    // ==================== 19. 使用自定义错误选择器回滚 ====================
    // 写入4字节错误selector，再revert；比字符串错误更节省Gas。
    function fail(bytes4 selector) internal pure {
        assembly { mstore(0, selector) revert(0, 4) }
    }
}
