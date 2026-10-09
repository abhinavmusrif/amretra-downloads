package com.amretra.devnet;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class IdentityStore {
    private static final String PREFS = "devnet_identity_v1";
    private static final String WRAP_ALIAS = "devnet_identity_wrap_v1";
    private static final String K_PUBLIC = "public";
    private static final String K_PRIVATE_CIPHER = "private_cipher";
    private static final String K_PRIVATE_IV = "private_iv";
    private static final String K_NODE_ID = "node_id";

    private final Context context;

    IdentityStore(Context context) {
        this.context = context.getApplicationContext();
    }

    synchronized IdentityStatus ensureIdentity() {
        try {
            SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
            String existing = p.getString(K_NODE_ID, null);
            if (existing != null && p.contains(K_PUBLIC) && p.contains(K_PRIVATE_CIPHER)) {
                return new IdentityStatus(true, existing, "ready");
            }

            KeyPairGenerator generator = KeyPairGenerator.getInstance("Ed25519");
            KeyPair pair = generator.generateKeyPair();
            byte[] privateBytes = pair.getPrivate().getEncoded();
            SecretKey wrappingKey = getOrCreateWrappingKey();

            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, wrappingKey, new SecureRandom());
            byte[] encrypted = cipher.doFinal(privateBytes);
            byte[] iv = cipher.getIV();

            String nodeId = "dm1_" + shortFingerprint(pair.getPublic().getEncoded());
            p.edit()
                    .putString(K_PUBLIC, Base64.encodeToString(pair.getPublic().getEncoded(), Base64.NO_WRAP))
                    .putString(K_PRIVATE_CIPHER, Base64.encodeToString(encrypted, Base64.NO_WRAP))
                    .putString(K_PRIVATE_IV, Base64.encodeToString(iv, Base64.NO_WRAP))
                    .putString(K_NODE_ID, nodeId)
                    .apply();

            return new IdentityStatus(true, nodeId, "created");
        } catch (Exception e) {
            return new IdentityStatus(false, null,
                    "Ed25519 identity unavailable on this runtime: " + e.getClass().getSimpleName());
        }
    }

    synchronized KeyPair loadKeyPair() throws Exception {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        byte[] publicBytes = Base64.decode(require(p, K_PUBLIC), Base64.NO_WRAP);
        byte[] encrypted = Base64.decode(require(p, K_PRIVATE_CIPHER), Base64.NO_WRAP);
        byte[] iv = Base64.decode(require(p, K_PRIVATE_IV), Base64.NO_WRAP);

        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateWrappingKey(), new GCMParameterSpec(128, iv));
        byte[] privateBytes = cipher.doFinal(encrypted);

        KeyFactory factory = KeyFactory.getInstance("Ed25519");
        PublicKey publicKey = factory.generatePublic(new X509EncodedKeySpec(publicBytes));
        PrivateKey privateKey = factory.generatePrivate(new PKCS8EncodedKeySpec(privateBytes));
        return new KeyPair(publicKey, privateKey);
    }

    String nodeId() {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(K_NODE_ID, "unprovisioned");
    }

    private SecretKey getOrCreateWrappingKey() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (store.containsAlias(WRAP_ALIAS)) {
            return ((KeyStore.SecretKeyEntry) store.getEntry(WRAP_ALIAS, null)).getSecretKey();
        }

        KeyGenerator kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        kg.init(new KeyGenParameterSpec.Builder(
                WRAP_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build());
        return kg.generateKey();
    }

    private static String shortFingerprint(byte[] input) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(input);
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < 20; i++) {
            b.append(String.format("%02x", digest[i]));
        }
        return b.toString();
    }

    private static String require(SharedPreferences p, String key) {
        String v = p.getString(key, null);
        if (v == null) throw new IllegalStateException("Missing identity field: " + key);
        return v;
    }

    static final class IdentityStatus {
        final boolean ready;
        final String nodeId;
        final String detail;

        IdentityStatus(boolean ready, String nodeId, String detail) {
            this.ready = ready;
            this.nodeId = nodeId;
            this.detail = detail;
        }
    }
}
