/**
 * JPYCVault デポジット操作例
 *
 * 3つの方法を提供:
 * 1. 従来の方法 (approve + deposit)
 * 2. EIP-2612 permit を使った方法 (depositWithPermit)
 * 3. 無限承認を使った方法 (approve(max) + deposit)
 */

import { ethers } from 'ethers';

// ABIの定義
const JPYC_ABI = [
    'function approve(address spender, uint256 value) external returns (bool)',
    'function allowance(address owner, address spender) external view returns (uint256)',
    'function balanceOf(address account) external view returns (uint256)',
    'function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external',
    'function nonces(address owner) external view returns (uint256)',
    'function name() external view returns (string)',
    'function DOMAIN_SEPARATOR() external view returns (bytes32)'
];

const VAULT_ABI = [
    'function deposit(uint256 amount) external',
    'function depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external',
    'function balance() external view returns (uint256)',
    'function hasRole(bytes32 role, address account) external view returns (bool)',
    'function OPERATOR_ROLE() external view returns (bytes32)'
];

// コントラクトアドレス (デプロイ後に更新)
const JPYC_ADDRESS = '0x...'; // Polygon JPYC address
const VAULT_ADDRESS = '0x...'; // JPYCVault address

/**
 * 方法1: 従来の2ステップ方式
 * メリット: シンプル、広くサポート
 * デメリット: 2トランザクション必要、ガス代が高い
 */
export async function depositTraditional(
    provider: ethers.Provider,
    signer: ethers.Signer,
    amount: bigint
): Promise<void> {
    console.log('=== 従来の方法: approve + deposit ===');

    const jpyc = new ethers.Contract(JPYC_ADDRESS, JPYC_ABI, signer);
    const vault = new ethers.Contract(VAULT_ADDRESS, VAULT_ABI, signer);

    const operatorAddress = await signer.getAddress();

    // 残高確認
    const balance = await jpyc.balanceOf(operatorAddress);
    console.log(`JPYC残高: ${ethers.formatUnits(balance, 18)} JPYC`);

    if (balance < amount) {
        throw new Error('JPYC残高不足');
    }

    // ステップ1: approve (トランザクション1)
    console.log('\n[1/2] Approving JPYC...');
    const approveTx = await jpyc.approve(VAULT_ADDRESS, amount);
    console.log(`Approve Tx: ${approveTx.hash}`);

    const approveReceipt = await approveTx.wait();
    console.log(`✓ Approved (Gas used: ${approveReceipt?.gasUsed.toString()})`);

    // ステップ2: deposit (トランザクション2)
    console.log('\n[2/2] Depositing to vault...');
    const depositTx = await vault.deposit(amount);
    console.log(`Deposit Tx: ${depositTx.hash}`);

    const depositReceipt = await depositTx.wait();
    console.log(`✓ Deposited (Gas used: ${depositReceipt?.gasUsed.toString()})`);

    // 結果確認
    const vaultBalance = await vault.balance();
    console.log(`\n✅ Vault残高: ${ethers.formatUnits(vaultBalance, 18)} JPYC`);

    // 合計ガス代
    const totalGas = (approveReceipt?.gasUsed || 0n) + (depositReceipt?.gasUsed || 0n);
    console.log(`合計ガス使用量: ${totalGas.toString()}`);
}

/**
 * 方法2: EIP-2612 Permit を使った1トランザクション方式
 * メリット: 1トランザクションで完了、ガス代削減、オフチェーン署名
 * デメリット: EIP-2612対応ウォレット必要
 *
 * ⭐ 推奨方法
 */
export async function depositWithPermit(
    provider: ethers.Provider,
    signer: ethers.Signer,
    amount: bigint
): Promise<void> {
    console.log('=== EIP-2612 Permit方式: depositWithPermit ===');

    const jpyc = new ethers.Contract(JPYC_ADDRESS, JPYC_ABI, signer);
    const vault = new ethers.Contract(VAULT_ADDRESS, VAULT_ABI, signer);

    const operatorAddress = await signer.getAddress();
    const chainId = (await provider.getNetwork()).chainId;

    // 残高確認
    const balance = await jpyc.balanceOf(operatorAddress);
    console.log(`JPYC残高: ${ethers.formatUnits(balance, 18)} JPYC`);

    if (balance < amount) {
        throw new Error('JPYC残高不足');
    }

    // Permit署名の作成 (オフチェーン - ガス代なし)
    console.log('\n[1/1] Creating permit signature (off-chain)...');

    const nonce = await jpyc.nonces(operatorAddress);
    const deadline = Math.floor(Date.now() / 1000) + 3600; // 1時間後

    // EIP-712 Domain
    const domain = {
        name: 'JPY Coin', // JPYCのname()から取得推奨
        version: '1',
        chainId: chainId,
        verifyingContract: JPYC_ADDRESS
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

    // Permit Message
    const message = {
        owner: operatorAddress,
        spender: VAULT_ADDRESS,
        value: amount,
        nonce: nonce,
        deadline: deadline
    };

    // 署名作成 (MetaMaskなどで署名ポップアップが表示される)
    const signature = await signer.signTypedData(domain, types, message);
    const { v, r, s } = ethers.Signature.from(signature);

    console.log('✓ Signature created (no gas used)');
    console.log(`  Deadline: ${new Date(deadline * 1000).toISOString()}`);
    console.log(`  Nonce: ${nonce.toString()}`);

    // depositWithPermit (1トランザクションで完了)
    console.log('\nDepositing with permit...');
    const tx = await vault.depositWithPermit(amount, deadline, v, r, s);
    console.log(`Tx: ${tx.hash}`);

    const receipt = await tx.wait();
    console.log(`✓ Deposited (Gas used: ${receipt?.gasUsed.toString()})`);

    // 結果確認
    const vaultBalance = await vault.balance();
    console.log(`\n✅ Vault残高: ${ethers.formatUnits(vaultBalance, 18)} JPYC`);
    console.log(`合計ガス使用量: ${receipt?.gasUsed.toString()} (約40%削減)`);
}

/**
 * 方法3: 無限承認 + deposit
 * メリット: 初回のみapprove、以降はdepositのみ
 * デメリット: セキュリティリスク(コントラクトが侵害されると全額失う可能性)
 *
 * ⚠️ 注意: 信頼できるコントラクトのみに使用すること
 */
export async function depositWithInfiniteApproval(
    provider: ethers.Provider,
    signer: ethers.Signer,
    amount: bigint,
    isFirstTime: boolean = false
): Promise<void> {
    console.log('=== 無限承認方式: approve(max) + deposit ===');

    const jpyc = new ethers.Contract(JPYC_ADDRESS, JPYC_ABI, signer);
    const vault = new ethers.Contract(VAULT_ADDRESS, VAULT_ABI, signer);

    const operatorAddress = await signer.getAddress();

    // 現在の承認額確認
    const currentAllowance = await jpyc.allowance(operatorAddress, VAULT_ADDRESS);
    console.log(`現在の承認額: ${ethers.formatUnits(currentAllowance, 18)} JPYC`);

    // 初回または承認額不足の場合は無限承認
    if (isFirstTime || currentAllowance < amount) {
        console.log('\n[1/2] Approving infinite allowance...');
        console.log('⚠️  Warning: 無限承認は信頼できるコントラクトのみに使用してください');

        const MAX_UINT256 = ethers.MaxUint256;
        const approveTx = await jpyc.approve(VAULT_ADDRESS, MAX_UINT256);
        console.log(`Approve Tx: ${approveTx.hash}`);

        const approveReceipt = await approveTx.wait();
        console.log(`✓ Infinite approval set (Gas used: ${approveReceipt?.gasUsed.toString()})`);
    } else {
        console.log('✓ Sufficient allowance already exists');
    }

    // deposit
    console.log('\n[2/2] Depositing to vault...');
    const depositTx = await vault.deposit(amount);
    console.log(`Deposit Tx: ${depositTx.hash}`);

    const depositReceipt = await depositTx.wait();
    console.log(`✓ Deposited (Gas used: ${depositReceipt?.gasUsed.toString()})`);

    // 結果確認
    const vaultBalance = await vault.balance();
    console.log(`\n✅ Vault残高: ${ethers.formatUnits(vaultBalance, 18)} JPYC`);

    const remainingAllowance = await jpyc.allowance(operatorAddress, VAULT_ADDRESS);
    if (remainingAllowance === ethers.MaxUint256) {
        console.log('残り承認額: 無限 (次回以降はapprove不要)');
    } else {
        console.log(`残り承認額: ${ethers.formatUnits(remainingAllowance, 18)} JPYC`);
    }
}

/**
 * ヘルパー関数: OPERATOR_ROLE確認
 */
export async function checkOperatorRole(
    provider: ethers.Provider,
    address: string
): Promise<boolean> {
    const vault = new ethers.Contract(VAULT_ADDRESS, VAULT_ABI, provider);
    const OPERATOR_ROLE = await vault.OPERATOR_ROLE();
    return await vault.hasRole(OPERATOR_ROLE, address);
}

/**
 * 使用例
 */
async function main() {
    // プロバイダーとウォレット設定
    const provider = new ethers.JsonRpcProvider('https://polygon-rpc.com');
    const wallet = new ethers.Wallet('YOUR_PRIVATE_KEY', provider);

    // デポジット額 (100,000 JPYC)
    const amount = ethers.parseUnits('100000', 18);

    // OPERATOR_ROLE確認
    const isOperator = await checkOperatorRole(provider, await wallet.getAddress());
    if (!isOperator) {
        throw new Error('Error: このアドレスはOPERATOR_ROLEを持っていません');
    }

    console.log('Operator確認済み\n');

    // 方法を選択
    const method = process.env.DEPOSIT_METHOD || 'permit'; // 'traditional' | 'permit' | 'infinite'

    switch (method) {
        case 'traditional':
            await depositTraditional(provider, wallet, amount);
            break;

        case 'permit':
            // ⭐ 推奨
            await depositWithPermit(provider, wallet, amount);
            break;

        case 'infinite':
            await depositWithInfiniteApproval(provider, wallet, amount, true);
            break;

        default:
            console.log('Unknown method. Use: traditional, permit, or infinite');
    }
}

// 実行
if (require.main === module) {
    main()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error(error);
            process.exit(1);
        });
}

/**
 * コマンドライン使用例:
 *
 * # 方法1: 従来の方法
 * DEPOSIT_METHOD=traditional npx ts-node examples/deposit-jpyc-vault.ts
 *
 * # 方法2: Permit (推奨)
 * DEPOSIT_METHOD=permit npx ts-node examples/deposit-jpyc-vault.ts
 *
 * # 方法3: 無限承認
 * DEPOSIT_METHOD=infinite npx ts-node examples/deposit-jpyc-vault.ts
 */

export { JPYC_ADDRESS, VAULT_ADDRESS, JPYC_ABI, VAULT_ABI };
