# Receiver V2 デプロイ・運用ガイド

ReceiverV2は、JPYCVaultへの依存を排除し、Receiver自身がJPYCを保持するシンプルな設計です。

## 📋 目次

- [V1 vs V2 比較](#v1-vs-v2-比較)
- [V2の利点](#v2の利点)
- [デプロイ手順](#デプロイ手順)
- [運用手順](#運用手順)
- [トラブルシューティング](#トラブルシューティング)

---

## V1 vs V2 比較

### アーキテクチャの違い

#### V1 (JPYCVault使用)

```
┌─────────────────┐
│  Operator       │
└────────┬────────┘
         │ deposit JPYC
         ↓
┌─────────────────┐
│   JPYCVault     │
│                 │
│  - OPERATOR_ROLE│
│  - EXCHANGE_ROLE│
└────────┬────────┘
         │ withdraw JPYC
         │ (EXCHANGE_ROLE required)
         ↓
┌─────────────────┐
│    Receiver     │
│                 │
│  ├─ REQUEST msg │
│  └─ Transfer to │
│     recipient   │
└─────────────────┘
```

**必要な設定:**
1. JPYCVault のデプロイ
2. OPERATOR_ROLE の付与
3. EXCHANGE_ROLE の付与（Receiverに）
4. Vaultへの JPYC入金

#### V2 (自己管理)

```
┌─────────────────┐
│  Owner          │
└────────┬────────┘
         │ depositJPYC
         ↓
┌─────────────────┐
│    ReceiverV2   │
│                 │
│  ├─ JPYC balance│
│  ├─ REQUEST msg │
│  └─ Transfer to │
│     recipient   │
└─────────────────┘
```

**必要な設定:**
1. ReceiverV2 のデプロイ
2. ReceiverへのJPYC入金（depositJPYC）

---

## V2の利点

| 項目 | V1 | V2 |
|------|----|----|
| **依存関係** | JPYCVault必須 | 不要 |
| **権限管理** | EXCHANGE_ROLE設定必要 | 不要 |
| **デプロイ手順** | 複雑（Vault + Receiver） | シンプル（Receiverのみ） |
| **運用** | Vault経由 | 直接管理 |
| **ガス代** | 高い（Vault経由） | 低い（直接transfer） |
| **独立性** | Vaultに依存 | 完全独立 |
| **柔軟性** | Vault共有 | Receiver個別管理 |

### ✅ V2推奨シナリオ

- シンプルな構成を好む場合
- Receiver毎に独立したJPYC管理が必要
- デプロイ・運用を簡素化したい
- ガス代を削減したい

### ⚠️ V1推奨シナリオ

- 複数Receiverで共通のJPYC流動性プールを使いたい
- 中央集権的な資金管理が必要
- 既存システムとの統合でVaultパターンが必須

---

## デプロイ手順

### Option A: LayerZero V2 (NLPOAppJPYCReceiverV2)

```bash
forge create src/NLPOAppJPYCReceiverV2.sol:NLPOAppJPYCReceiverV2 \
  --rpc-url $POLYGON_RPC \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    $JPYC_ADDRESS \
    $LZ_ENDPOINT_V2 \
    $OWNER_ADDRESS \
  --verify
```

**パラメータ:**
- `$JPYC_ADDRESS`: JPYC token address (Polygon: `0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c`)
- `$LZ_ENDPOINT_V2`: LayerZero Endpoint V2 address
- `$OWNER_ADDRESS`: Owner address (your wallet)

### Option B: Chainlink CCIP (NLPCCIPJPYCReceiverV2)

```bash
forge create src/NLPCCIPJPYCReceiverV2.sol:NLPCCIPJPYCReceiverV2 \
  --rpc-url $POLYGON_RPC \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    $JPYC_ADDRESS \
    $CCIP_ROUTER \
    $LINK_TOKEN \
    $OWNER_ADDRESS \
  --verify
```

**パラメータ:**
- `$JPYC_ADDRESS`: JPYC token address
- `$CCIP_ROUTER`: CCIP Router address
- `$LINK_TOKEN`: LINK token address
- `$OWNER_ADDRESS`: Owner address

---

## 運用手順

### 1. 初期設定

#### 1.1 Peerの設定 (LayerZero)

```bash
# ReceiverからAdapterへのpeerを設定
cast send $RECEIVER_V2_ADDRESS \
  "setPeer(uint32,bytes32)" \
  $SONEIUM_EID \
  $(cast --to-bytes32 $ADAPTER_ADDRESS) \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC
```

#### 1.2 Source Chain設定 (CCIP)

```bash
cast send $RECEIVER_V2_ADDRESS \
  "configureSourceChain(uint64,address)" \
  $SONEIUM_CHAIN_SELECTOR \
  $ADAPTER_ADDRESS \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC
```

### 2. JPYC入金

#### 方法1: depositJPYC (推奨)

```typescript
// 1. Approve
await jpyc.approve(receiverV2Address, amount);

// 2. Deposit
await receiverV2.depositJPYC(amount);
```

```bash
# Cast version
# 1. Approve
cast send $JPYC_ADDRESS \
  "approve(address,uint256)" \
  $RECEIVER_V2_ADDRESS \
  $AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC

# 2. Deposit
cast send $RECEIVER_V2_ADDRESS \
  "depositJPYC(uint256)" \
  $AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC
```

#### depositWithPermit も利用可能

JPYCはEIP-2612をサポートしているため、1トランザクションで入金可能:

```typescript
// 1. Create permit signature (off-chain)
const signature = await owner.signTypedData(domain, types, message);
const { v, r, s } = ethers.Signature.from(signature);

// 2. Call custom depositJPYCWithPermit if implemented
// (Or call permit + depositJPYC separately)
```

### 3. 残高確認

```bash
# JPYC balance
cast call $RECEIVER_V2_ADDRESS \
  "jpycBalance()(uint256)" \
  --rpc-url $POLYGON_RPC

# Format output
cast --from-wei $(cast call $RECEIVER_V2_ADDRESS "jpycBalance()(uint256)" --rpc-url $POLYGON_RPC)
```

### 4. レスポンスメッセージ用の資金

#### LayerZero (Native Token)

```bash
# Fund receiver with native tokens
cast send $RECEIVER_V2_ADDRESS \
  --value 1ether \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC

# Or use fundForResponses()
cast send $RECEIVER_V2_ADDRESS \
  "fundForResponses()" \
  --value 1ether \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC
```

#### CCIP (LINK Token)

```bash
# 1. Approve LINK
cast send $LINK_TOKEN \
  "approve(address,uint256)" \
  $RECEIVER_V2_ADDRESS \
  $LINK_AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC

# 2. Fund receiver
cast send $RECEIVER_V2_ADDRESS \
  "fundForResponses(uint256)" \
  $LINK_AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC
```

### 5. 為替レート設定

```bash
# Set exchange rate (10000 = 1:1, 9000 = 0.9:1)
cast send $RECEIVER_V2_ADDRESS \
  "setExchangeRate(uint256)" \
  10000 \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC
```

---

## モニタリング

### JPYC残高監視

```bash
#!/bin/bash
# monitor-jpyc-balance.sh

RECEIVER=$RECEIVER_V2_ADDRESS
RPC=$POLYGON_RPC
THRESHOLD=100000000000000000000000  # 100,000 JPYC

while true; do
    BALANCE=$(cast call $RECEIVER "jpycBalance()(uint256)" --rpc-url $RPC)

    if [ "$BALANCE" -lt "$THRESHOLD" ]; then
        echo "⚠️  WARNING: JPYC balance low!"
        echo "Current: $(cast --from-wei $BALANCE) JPYC"
        echo "Threshold: $(cast --from-wei $THRESHOLD) JPYC"
        # Send alert (email, Slack, etc.)
    fi

    sleep 300  # Check every 5 minutes
done
```

### イベント監視

```typescript
// Monitor JPYCTransferred events
receiverV2.on("JPYCTransferred", (recipient, jpycAmount, nlpAmount) => {
  console.log(`✅ JPYC Transferred:`);
  console.log(`  Recipient: ${recipient}`);
  console.log(`  JPYC: ${ethers.formatUnits(jpycAmount, 18)}`);
  console.log(`  NLP: ${ethers.formatUnits(nlpAmount, 18)}`);
});

// Monitor JPYCTransferFailed events
receiverV2.on("JPYCTransferFailed", (recipient, jpycAmount, nlpAmount, reason) => {
  console.error(`❌ JPYC Transfer Failed:`);
  console.error(`  Recipient: ${recipient}`);
  console.error(`  JPYC: ${ethers.formatUnits(jpycAmount, 18)}`);
  console.error(`  Reason: ${reason}`);
  // Send alert
});
```

---

## JPYC出金

緊急時またはメンテナンス時にJPYCを出金:

```bash
cast send $RECEIVER_V2_ADDRESS \
  "withdrawJPYC(address,uint256)" \
  $RECIPIENT_ADDRESS \
  $AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC
```

---

## トラブルシューティング

### JPYC転送が失敗する

**原因1: 残高不足**
```
Error: Insufficient JPYC balance
```

**解決:**
```bash
# 残高確認
cast call $RECEIVER_V2_ADDRESS "jpycBalance()(uint256)" --rpc-url $POLYGON_RPC

# JPYCを入金
# (上記「JPYC入金」参照)
```

**原因2: JPYCがpausedまたはblocklistに登録**

JPYCはPausableとBlocklistable機能を持っています。

```bash
# Pausedチェック
cast call $JPYC_ADDRESS "paused()(bool)" --rpc-url $POLYGON_RPC

# Blocklistチェック
cast call $JPYC_ADDRESS \
  "isBlocklisted(address)(bool)" \
  $RECIPIENT_ADDRESS \
  --rpc-url $POLYGON_RPC
```

### Response送信失敗

**原因: Native token / LINK不足**

```bash
# LayerZero: Native balance確認
cast balance $RECEIVER_V2_ADDRESS --rpc-url $POLYGON_RPC

# CCIP: LINK balance確認
cast call $LINK_TOKEN \
  "balanceOf(address)(uint256)" \
  $RECEIVER_V2_ADDRESS \
  --rpc-url $POLYGON_RPC
```

**解決:**
```bash
# 上記「レスポンスメッセージ用の資金」参照
```

---

## セキュリティチェックリスト

デプロイ前:
- [ ] Owner addressがmultisigまたは安全なwallet
- [ ] 適切な為替レート設定
- [ ] 十分なJPYC残高を入金
- [ ] Response用の資金を入金
- [ ] Peer/Source chain設定完了

運用中:
- [ ] JPYC残高を定期的にモニタリング
- [ ] JPYCTransferFailedイベントを監視
- [ ] Response用の資金残高を監視
- [ ] 異常なトランザクションをアラート

---

## V1からV2への移行

### 移行手順

1. **V2 Receiverをデプロイ**
```bash
forge create src/NLPOAppJPYCReceiverV2.sol:NLPOAppJPYCReceiverV2 ...
```

2. **V2に切り替え**
```bash
# Adapter側でReceiverアドレスを更新
cast send $ADAPTER_ADDRESS \
  "setPeer(uint32,bytes32)" \
  $POLYGON_EID \
  $(cast --to-bytes32 $RECEIVER_V2_ADDRESS) \
  --private-key $PRIVATE_KEY \
  --rpc-url $SONEIUM_RPC
```

3. **V2にJPYCを入金**
```bash
# 方法A: VaultからV2に移動
# 1. Vault pause
cast send $VAULT_ADDRESS "pause()" --private-key $ADMIN_KEY --rpc-url $POLYGON_RPC

# 2. Vault emergency withdraw
cast send $VAULT_ADDRESS \
  "emergencyWithdraw(address)" \
  $OWNER_ADDRESS \
  --private-key $ADMIN_KEY \
  --rpc-url $POLYGON_RPC

# 3. V2に入金
cast send $JPYC_ADDRESS "approve(address,uint256)" $RECEIVER_V2_ADDRESS $AMOUNT ...
cast send $RECEIVER_V2_ADDRESS "depositJPYC(uint256)" $AMOUNT ...
```

4. **動作確認**
```bash
# Test transfer
# (Integration testを実行)
```

5. **V1停止** (必要に応じて)
```bash
# V1 Receiverへのメッセージを無効化
# Adapterから古いpeerを削除など
```

---

## 参考資料

- [CLAUDE.md](./CLAUDE.md) - プロジェクト概要
- [ARCHITECTURE.md](./ARCHITECTURE.md) - アーキテクチャ詳細
- [DEPOSIT_GUIDE.md](./DEPOSIT_GUIDE.md) - JPYCVault入金ガイド（V1用）
- [ReceiverV2Test.t.sol](./test/ReceiverV2Test.t.sol) - V2テストコード

---

## まとめ

**ReceiverV2の主な特徴:**

✅ **シンプル**: JPYCVault不要
✅ **独立性**: Receiver自身がJPYC管理
✅ **低コスト**: 直接transfer、ガス削減
✅ **簡単デプロイ**: 権限設定不要
✅ **柔軟性**: Receiver毎に独立管理

**推奨構成:**
- 新規デプロイ → V2を使用
- 既存システム → V1継続または徐々にV2移行
- 複数Receiver → 各ReceiverにV2を独立デプロイ

V2はより実用的でシンプルな設計となっています🎉
