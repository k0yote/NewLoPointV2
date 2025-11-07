#!/bin/bash

# JPYCVault デポジット操作スクリプト
# Foundry (cast) を使用

set -e

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 設定
JPYC_ADDRESS="${JPYC_ADDRESS:-0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c}" # Polygon JPYC
VAULT_ADDRESS="${VAULT_ADDRESS:-YOUR_VAULT_ADDRESS}"
RPC_URL="${RPC_URL:-https://polygon-rpc.com}"
PRIVATE_KEY="${PRIVATE_KEY}"

# 引数チェック
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY environment variable not set${NC}"
    echo "Usage: PRIVATE_KEY=0x... ./deposit-jpyc-vault.sh <method> <amount>"
    exit 1
fi

METHOD="${1:-permit}"
AMOUNT="${2:-100000}" # デフォルト 100,000 JPYC

# wei変換 (18 decimals)
AMOUNT_WEI=$(cast --to-wei "$AMOUNT")

echo -e "${BLUE}=== JPYCVault Deposit ===${NC}"
echo "Method: $METHOD"
echo "Amount: $AMOUNT JPYC"
echo "Vault: $VAULT_ADDRESS"
echo ""

# アドレス取得
OPERATOR_ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "Operator: $OPERATOR_ADDRESS"

# JPYC残高確認
JPYC_BALANCE=$(cast call "$JPYC_ADDRESS" \
    "balanceOf(address)(uint256)" \
    "$OPERATOR_ADDRESS" \
    --rpc-url "$RPC_URL")

JPYC_BALANCE_FORMATTED=$(cast --from-wei "$JPYC_BALANCE")
echo "JPYC Balance: $JPYC_BALANCE_FORMATTED JPYC"

if [ "$(echo "$JPYC_BALANCE_FORMATTED < $AMOUNT" | bc)" -eq 1 ]; then
    echo -e "${RED}Error: Insufficient JPYC balance${NC}"
    exit 1
fi

# OPERATOR_ROLE確認
OPERATOR_ROLE=$(cast call "$VAULT_ADDRESS" \
    "OPERATOR_ROLE()(bytes32)" \
    --rpc-url "$RPC_URL")

HAS_ROLE=$(cast call "$VAULT_ADDRESS" \
    "hasRole(bytes32,address)(bool)" \
    "$OPERATOR_ROLE" \
    "$OPERATOR_ADDRESS" \
    --rpc-url "$RPC_URL")

if [ "$HAS_ROLE" != "true" ]; then
    echo -e "${RED}Error: Address does not have OPERATOR_ROLE${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Operator role confirmed${NC}"
echo ""

# デポジット方法に応じて実行
case "$METHOD" in
    traditional)
        echo -e "${YELLOW}Method 1: Traditional (approve + deposit)${NC}"
        echo ""

        # Step 1: Approve
        echo "[1/2] Approving JPYC..."
        APPROVE_TX=$(cast send "$JPYC_ADDRESS" \
            "approve(address,uint256)" \
            "$VAULT_ADDRESS" \
            "$AMOUNT_WEI" \
            --private-key "$PRIVATE_KEY" \
            --rpc-url "$RPC_URL" \
            --json)

        APPROVE_HASH=$(echo "$APPROVE_TX" | jq -r '.transactionHash')
        echo -e "${GREEN}✓ Approved${NC}"
        echo "Tx: $APPROVE_HASH"
        echo ""

        # Step 2: Deposit
        echo "[2/2] Depositing to vault..."
        DEPOSIT_TX=$(cast send "$VAULT_ADDRESS" \
            "deposit(uint256)" \
            "$AMOUNT_WEI" \
            --private-key "$PRIVATE_KEY" \
            --rpc-url "$RPC_URL" \
            --json)

        DEPOSIT_HASH=$(echo "$DEPOSIT_TX" | jq -r '.transactionHash')
        echo -e "${GREEN}✓ Deposited${NC}"
        echo "Tx: $DEPOSIT_HASH"
        ;;

    permit)
        echo -e "${YELLOW}Method 2: Permit (depositWithPermit) ⭐ Recommended${NC}"
        echo ""
        echo -e "${RED}Note: Permit signature creation via shell is complex.${NC}"
        echo -e "${RED}Please use the TypeScript example or Foundry script instead.${NC}"
        echo ""
        echo "Example with Foundry script:"
        echo "  forge script script/DepositWithPermit.s.sol --rpc-url \$RPC_URL --broadcast"
        exit 1
        ;;

    infinite)
        echo -e "${YELLOW}Method 3: Infinite Approval${NC}"
        echo -e "${RED}⚠️  Warning: This grants unlimited approval. Use only for trusted contracts.${NC}"
        echo ""

        # 現在の承認額確認
        CURRENT_ALLOWANCE=$(cast call "$JPYC_ADDRESS" \
            "allowance(address,address)(uint256)" \
            "$OPERATOR_ADDRESS" \
            "$VAULT_ADDRESS" \
            --rpc-url "$RPC_URL")

        echo "Current allowance: $(cast --from-wei $CURRENT_ALLOWANCE) JPYC"

        # 無限承認が必要か確認
        if [ "$(echo "$CURRENT_ALLOWANCE < $AMOUNT_WEI" | bc)" -eq 1 ]; then
            echo "[1/2] Setting infinite approval..."

            MAX_UINT256="115792089237316195423570985008687907853269984665640564039457584007913129639935"

            APPROVE_TX=$(cast send "$JPYC_ADDRESS" \
                "approve(address,uint256)" \
                "$VAULT_ADDRESS" \
                "$MAX_UINT256" \
                --private-key "$PRIVATE_KEY" \
                --rpc-url "$RPC_URL" \
                --json)

            APPROVE_HASH=$(echo "$APPROVE_TX" | jq -r '.transactionHash')
            echo -e "${GREEN}✓ Infinite approval set${NC}"
            echo "Tx: $APPROVE_HASH"
        else
            echo -e "${GREEN}✓ Sufficient allowance exists${NC}"
        fi
        echo ""

        # Deposit
        echo "[2/2] Depositing to vault..."
        DEPOSIT_TX=$(cast send "$VAULT_ADDRESS" \
            "deposit(uint256)" \
            "$AMOUNT_WEI" \
            --private-key "$PRIVATE_KEY" \
            --rpc-url "$RPC_URL" \
            --json)

        DEPOSIT_HASH=$(echo "$DEPOSIT_TX" | jq -r '.transactionHash')
        echo -e "${GREEN}✓ Deposited${NC}"
        echo "Tx: $DEPOSIT_HASH"
        ;;

    *)
        echo -e "${RED}Unknown method: $METHOD${NC}"
        echo "Available methods: traditional, permit, infinite"
        exit 1
        ;;
esac

echo ""
echo -e "${BLUE}=== Result ===${NC}"

# Vault残高確認
VAULT_BALANCE=$(cast call "$VAULT_ADDRESS" \
    "balance()(uint256)" \
    --rpc-url "$RPC_URL")

VAULT_BALANCE_FORMATTED=$(cast --from-wei "$VAULT_BALANCE")
echo "Vault Balance: $VAULT_BALANCE_FORMATTED JPYC"

echo -e "${GREEN}✅ Deposit completed successfully!${NC}"
