#!/bin/bash
# Generate a fixed release keystore for Android APK signing.
# Run once and commit upload-keystore.jks to the repo.
keytool -genkey -v \
  -keystore upload-keystore.jks \
  -alias sena-repo \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass senarepo \
  -keypass senarepo \
  -dname "CN=Sena Repo, OU=Dev, O=SenaRepo, L=Unknown, ST=Unknown, C=CN"
echo "Generated upload-keystore.jks"
echo "IMPORTANT: Add upload-keystore.jks to .gitignore IF this is a private repo, or commit it for CI."
