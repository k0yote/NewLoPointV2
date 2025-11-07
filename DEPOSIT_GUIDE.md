# JPYCVault デポジット操作ガイド

JPYCVaultへのデポジット方法を3つのパターンで説明します。

## 📋 目次

- [前提条件](#前提条件)
- [方法1: 従来の方法 (approve + deposit)](#方法1-従来の方法)
- [方法2: EIP-2612 Permit (depositWithPermit) ⭐推奨](#方法2-eip-2612-permit)
- [方法3: 無限承認 (Infinite Approval)](#方法3-無限承認)
- [比較表](#比較表)
- [トラブルシューティング](#トラブルシューティング)

---

## 前提条件

### 必要な権限

JPYCVaultにデポジットするには、以下の条件を満たす必要があります：

1. **OPERATOR_ROLE** を持っていること
2. 十分な **JPYC残高** があること
3. Vaultが **paused状態でない** こと

### 権限確認方法

```bash
# OPERATOR_ROLE確認
cast call $VAULT_ADDRESS \
  "hasRole(bytes32,address)(bool)" \
  $(cast call $VAULT_ADDRESS "OPERATOR_ROLE()(bytes32)") \
  $YOUR_ADDRESS \
  --rpc-url $POLYGON_RPC
```

### コントラクトアドレス

- **JPYC (Polygon)**: `0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c`
- **JPYCVault**: デプロイ後のアドレス

---

## 方法1: 従来の方法

### 概要

最も標準的な方法。2つのトランザクションが必要です。

**メリット:**
- シンプルで理解しやすい
- すべてのウォレットで動作
- 広くサポートされている

**デメリット:**
- 2回のトランザクションが必要
- ガス代が高い（約111k gas）
- UXが悪い（2回署名が必要）

### 実装例

#### TypeScript (ethers.js)

```typescript
import { ethers } from 'ethers';

const provider = new ethers.JsonRpcProvider('https://polygon-rpc.com');
const wallet = new ethers.Wallet('YOUR_PRIVATE_KEY', provider);

const jpycAddress = '0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c';
const vaultAddress = 'YOUR_VAULT_ADDRESS';

const jpyc = new ethers.Contract(jpycAddress, [
  'function approve(address spender, uint256 value) external returns (bool)'
], wallet);

const vault = new ethers.Contract(vaultAddress, [
  'function deposit(uint256 amount) external'
], wallet);

const amount = ethers.parseUnits('100000', 18); // 100,000 JPYC

// ステップ1: Approve
console.log('Approving...');
const approveTx = await jpyc.approve(vaultAddress, amount);
await approveTx.wait();
console.log('✓ Approved');

// ステップ2: Deposit
console.log('Depositing...');
const depositTx = await vault.deposit(amount);
await depositTx.wait();
console.log('✓ Deposited');
```

#### Foundry Script

```bash
# 環境変数設定
export JPYC_ADDRESS=0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c
export VAULT_ADDRESS=YOUR_VAULT_ADDRESS
export DEPOSIT_AMOUNT=100000000000000000000000  # 100,000 JPYC (wei)
export PRIVATE_KEY=YOUR_PRIVATE_KEY

# 実行
forge script script/DepositWithPermit.s.sol:TraditionalDeposit \
  --rpc-url https://polygon-rpc.com \
  --broadcast
```

#### Cast (CLI)

```bash
# ステップ1: Approve
cast send $JPYC_ADDRESS \
  "approve(address,uint256)" \
  $VAULT_ADDRESS \
  $(cast --to-wei 100000) \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC

# ステップ2: Deposit
cast send $VAULT_ADDRESS \
  "deposit(uint256)" \
  $(cast --to-wei 100000) \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC
```

---

## 方法2: EIP-2612 Permit

### 概要 ⭐ **推奨方法**

EIP-2612 permitを使用することで、**1つのトランザクション**でデポジットが完了します。

**メリット:**
- 1トランザクションで完了
- ガス代削減（約66k gas、40%削減）
- 優れたUX（署名は1回のみ）
- オフチェーン署名（初回署名はガス代不要）

**デメリット:**
- EIP-2612対応ウォレット必要（MetaMask等は対応済み）
- 実装がやや複雑

### 仕組み

```
1. ユーザーがオフチェーンでpermit署名を作成 (ガス代なし)
   ↓
2. depositWithPermit()を呼び出し
   ↓
3. Vault内でpermit()を実行して承認
   ↓
4. safeTransferFrom()でJPYCを転送
   ↓
5. 完了 (1トランザクションのみ)
```

### 実装例

#### TypeScript (ethers.js)

```typescript
import { ethers } from 'ethers';

const provider = new ethers.JsonRpcProvider('https://polygon-rpc.com');
const wallet = new ethers.Wallet('YOUR_PRIVATE_KEY', provider);

const jpycAddress = '0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c';
const vaultAddress = 'YOUR_VAULT_ADDRESS';
const amount = ethers.parseUnits('100000', 18);

// JPYC Contract
const jpyc = new ethers.Contract(jpycAddress, [
  'function nonces(address owner) external view returns (uint256)',
  'function name() external view returns (string)'
], provider);

// Vault Contract
const vault = new ethers.Contract(vaultAddress, [
  'function depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external'
], wallet);

// Permit署名作成
const deadline = Math.floor(Date.now() / 1000) + 3600; // 1時間後
const nonce = await jpyc.nonces(wallet.address);
const chainId = (await provider.getNetwork()).chainId;

// EIP-712 Domain
const domain = {
  name: await jpyc.name(), // "JPY Coin"
  version: '1',
  chainId: chainId,
  verifyingContract: jpycAddress
};

// EIP-712 Types
const types = {
  Permit: [
    { name: 'owner', type: 'address' },
    { name: 'spender', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' }
  ]
};

// Message
const message = {
  owner: wallet.address,
  spender: vaultAddress,
  value: amount,
  nonce: nonce,
  deadline: deadline
};

// 署名作成（MetaMaskポップアップ表示）
console.log('Creating permit signature...');
const signature = await wallet.signTypedData(domain, types, message);
const { v, r, s } = ethers.Signature.from(signature);

// 1トランザクションでデポジット完了
console.log('Depositing with permit...');
const tx = await vault.depositWithPermit(amount, deadline, v, r, s);
await tx.wait();
console.log('✓ Deposited!');
```

#### Foundry Script

```bash
# 直接パラメータ指定
forge script script/DepositWithPermit.s.sol:DepositWithPermit \
  --rpc-url https://polygon-rpc.com \
  --broadcast \
  --private-key $PRIVATE_KEY \
  --sig "run(address,address,uint256)" \
  0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c \
  $VAULT_ADDRESS \
  100000000000000000000000

# または環境変数から
export JPYC_ADDRESS=0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c
export VAULT_ADDRESS=YOUR_VAULT_ADDRESS
export DEPOSIT_AMOUNT=100000000000000000000000

forge script script/DepositWithPermit.s.sol:DepositWithPermit \
  --rpc-url https://polygon-rpc.com \
  --broadcast \
  --sig "runFromEnv()"
```

#### Python (web3.py)

```python
from web3 import Web3
from eth_account import Account
from eth_account.messages import encode_structured_data

w3 = Web3(Web3.HTTPProvider('https://polygon-rpc.com'))
account = Account.from_key('YOUR_PRIVATE_KEY')

jpyc_address = '0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c'
vault_address = 'YOUR_VAULT_ADDRESS'
amount = Web3.to_wei(100000, 'ether')

# Get nonce
jpyc = w3.eth.contract(address=jpyc_address, abi=[...])
nonce = jpyc.functions.nonces(account.address).call()

# Create permit message
deadline = int(time.time()) + 3600
chain_id = w3.eth.chain_id

structured_data = {
    "types": {
        "EIP712Domain": [
            {"name": "name", "type": "string"},
            {"name": "version", "type": "string"},
            {"name": "chainId", "type": "uint256"},
            {"name": "verifyingContract", "type": "address"}
        ],
        "Permit": [
            {"name": "owner", "type": "address"},
            {"name": "spender", "type": "address"},
            {"name": "value", "type": "uint256"},
            {"name": "nonce", "type": "uint256"},
            {"name": "deadline", "type": "uint256"}
        ]
    },
    "primaryType": "Permit",
    "domain": {
        "name": "JPY Coin",
        "version": "1",
        "chainId": chain_id,
        "verifyingContract": jpyc_address
    },
    "message": {
        "owner": account.address,
        "spender": vault_address,
        "value": amount,
        "nonce": nonce,
        "deadline": deadline
    }
}

# Sign
signed_message = account.sign_message(encode_structured_data(structured_data))

# Call depositWithPermit
vault = w3.eth.contract(address=vault_address, abi=[...])
tx = vault.functions.depositWithPermit(
    amount,
    deadline,
    signed_message.v,
    signed_message.r.to_bytes(32, 'big'),
    signed_message.s.to_bytes(32, 'big')
).build_transaction({
    'from': account.address,
    'nonce': w3.eth.get_transaction_count(account.address),
    'gas': 200000,
    'gasPrice': w3.eth.gas_price
})

signed_tx = account.sign_transaction(tx)
tx_hash = w3.eth.send_raw_transaction(signed_tx.rawTransaction)
print(f'Transaction: {tx_hash.hex()}')
```

---

## 方法3: 無限承認

### 概要

初回に無限承認(`type(uint256).max`)を設定し、以降は`deposit()`のみで実行。

**メリット:**
- 初回以降は1トランザクションのみ
- 実装がシンプル

**デメリット:**
- ⚠️ **セキュリティリスク**: コントラクトが侵害されると全額失う可能性
- 信頼できるコントラクトのみに使用すべき

### ⚠️ 注意事項

**無限承認は以下の場合のみ使用してください:**

1. コントラクトが完全に監査済み
2. コントラクトが信頼できるチームによって管理
3. 緊急時の対応計画がある
4. リスクを完全に理解している

### 実装例

#### TypeScript

```typescript
const MAX_UINT256 = ethers.MaxUint256;

// 初回: 無限承認
console.log('Setting infinite approval...');
const approveTx = await jpyc.approve(vaultAddress, MAX_UINT256);
await approveTx.wait();
console.log('✓ Infinite approval set');

// 以降: depositのみ
console.log('Depositing...');
const depositTx = await vault.deposit(amount);
await depositTx.wait();
console.log('✓ Deposited');

// 次回以降はdepositのみでOK
```

#### Cast

```bash
# 初回: 無限承認
MAX_UINT256="115792089237316195423570985008687907853269984665640564039457584007913129639935"

cast send $JPYC_ADDRESS \
  "approve(address,uint256)" \
  $VAULT_ADDRESS \
  $MAX_UINT256 \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC

# 以降: depositのみ
cast send $VAULT_ADDRESS \
  "deposit(uint256)" \
  $(cast --to-wei 100000) \
  --private-key $PRIVATE_KEY \
  --rpc-url $POLYGON_RPC
```

---

## 比較表

| 項目 | 従来の方法 | Permit ⭐ | 無限承認 |
|------|-----------|----------|---------|
| **トランザクション数** | 2回 | 1回 | 初回2回、以降1回 |
| **ガス代** | ~111k gas | ~66k gas | 初回~111k、以降~65k |
| **ガス削減率** | - | **40%削減** | 初回以降41%削減 |
| **UX** | 👎 2回署名 | 👍 1回署名 | 👍 初回以降1回 |
| **セキュリティ** | ✅ 安全 | ✅ 安全 | ⚠️ リスクあり |
| **実装難易度** | 簡単 | 中程度 | 簡単 |
| **ウォレット対応** | すべて | EIP-2612対応 | すべて |
| **推奨度** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ |

### 推奨事項

1. **一般的な場合**: **方法2 (Permit)** を使用
2. **古いウォレット**: 方法1 (従来) を使用
3. **頻繁なデポジット & 高信頼**: 方法3を検討（自己責任）

---

## トラブルシューティング

### エラー: "Not authorized" / AccessControl

```
原因: OPERATOR_ROLEを持っていない
解決: 管理者にOPERATOR_ROLEの付与を依頼
```

```bash
# 管理者が実行
cast send $VAULT_ADDRESS \
  "grantRole(bytes32,address)" \
  $(cast call $VAULT_ADDRESS "OPERATOR_ROLE()(bytes32)") \
  $OPERATOR_ADDRESS \
  --private-key $ADMIN_PRIVATE_KEY \
  --rpc-url $POLYGON_RPC
```

### エラー: "ZeroAmount"

```
原因: amount=0を指定
解決: 0より大きい金額を指定
```

### エラー: "Insufficient balance"

```
原因: JPYC残高不足
解決: JPYCを入手するか、デポジット額を減らす
```

### エラー: "EIP2612: permit is expired"

```
原因: deadline が過去の時刻
解決: deadlineを未来の時刻に設定
```

```typescript
// OK: 現在時刻 + 1時間
const deadline = Math.floor(Date.now() / 1000) + 3600;

// NG: 過去の時刻
const deadline = Math.floor(Date.now() / 1000) - 100;
```

### エラー: "EIP2612: invalid signature"

```
原因: permit署名が不正
解決:
1. domain、types、messageが正しいか確認
2. 署名に使用した秘密鍵とtx送信者が一致するか確認
3. nonceが最新か確認
```

### エラー: "Paused"

```
原因: Vaultがpaused状態
解決: 管理者にunpauseを依頼
```

```bash
# 管理者が実行
cast send $VAULT_ADDRESS \
  "unpause()" \
  --private-key $ADMIN_PRIVATE_KEY \
  --rpc-url $POLYGON_RPC
```

---

## サンプルコード

完全な実装例は以下を参照:

- TypeScript: [`examples/deposit-jpyc-vault.ts`](./examples/deposit-jpyc-vault.ts)
- Shell Script: [`examples/deposit-jpyc-vault.sh`](./examples/deposit-jpyc-vault.sh)
- Foundry Script: [`script/DepositWithPermit.s.sol`](./script/DepositWithPermit.s.sol)
- テスト: [`test/JPYCVault.t.sol`](./test/JPYCVault.t.sol)

---

## 関連ドキュメント

- [CLAUDE.md](./CLAUDE.md) - プロジェクト概要
- [ARCHITECTURE.md](./ARCHITECTURE.md) - アーキテクチャ詳細
- [SECURITY_AUDIT.md](./SECURITY_AUDIT.md) - セキュリティ監査
- [EIP-2612 Specification](https://eips.ethereum.org/EIPS/eip-2612)
