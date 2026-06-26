#!/bin/bash

# --- CONFIGURAÇÃO ---
DOMINIO="ajbarbosa.xyz"
USUARIO="terraform-user"
POLICY_NAME="ACMCertificateManagement"

echo "1. Criando arquivo de política localmente..."
cat <<INNER_EOF > acm-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ACMCertificateManagement",
            "Effect": "Allow",
            "Action": [
                "acm:RequestCertificate",
                "acm:DescribeCertificate",
                "acm:ListCertificates",
                "acm:GetCertificate",
                "acm:ListTagsForCertificate"
            ],
            "Resource": "*"
        }
    ]
}
INNER_EOF

echo "2. Criando a Policy na AWS..."
POLICY_ARN=$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document file://acm-policy.json \
    --query 'Policy.Arn' \
    --output text)

echo "Policy criada com ARN: $POLICY_ARN"

echo "3. Atachando a policy ao usuário $USUARIO..."
aws iam attach-user-policy \
    --user-name "$USUARIO" \
    --policy-arn "$POLICY_ARN"

echo "4. Solicitando certificado SSL no ACM (us-east-1)..."
NOVO_ARN=$(aws acm request-certificate \
    --domain-name "$DOMINIO" \
    --validation-method DNS \
    --region us-east-1 \
    --query 'CertificateArn' \
    --output text)

echo "---------------------------------------------------"
echo "✅ Sucesso!"
echo "ARN do Certificado: $NOVO_ARN"
echo "---------------------------------------------------"
