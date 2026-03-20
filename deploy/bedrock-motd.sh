#!/bin/bash
# Write MOTD banner and fix scripts for missing Bedrock form
mkdir -p /opt/openclaw
cat > /etc/motd << 'MSG'
WARNING: BEDROCK MODEL ACCESS NOT CONFIGURED

  Run: bash /opt/openclaw/fix-bedrock.sh
  Or: AWS Console > Bedrock > Model access > Enable Anthropic Claude
MSG

cat > /etc/profile.d/bedrock-check.sh << 'CHK'
#!/bin/bash
if aws bedrock get-use-case-for-model-access --region us-east-1 >/dev/null 2>&1; then
  if [ -f /etc/motd ] && grep -q "BEDROCK MODEL ACCESS" /etc/motd 2>/dev/null; then
    sudo rm -f /etc/motd
    echo "Bedrock model access is now configured!"
  fi
fi
CHK
chmod +x /etc/profile.d/bedrock-check.sh

cat > /opt/openclaw/fix-bedrock.sh << 'FIX'
#!/bin/bash
echo "Submitting Bedrock use case form..."
echo '{"companyName":"My Company","companyWebsite":"https://example.com","intendedUsers":"0","industryOption":"Education","otherIndustryOption":"","useCases":"AI development"}' > /tmp/bedrock-form.json
aws bedrock put-use-case-for-model-access --form-data fileb:///tmp/bedrock-form.json --region us-east-1
if aws bedrock get-use-case-for-model-access --region us-east-1 >/dev/null 2>&1; then
  echo "Form submitted! Model access will activate in ~15 minutes."
  sudo rm -f /etc/motd
else
  echo "Submission failed. Try the AWS Console instead."
fi
FIX
chmod +x /opt/openclaw/fix-bedrock.sh
