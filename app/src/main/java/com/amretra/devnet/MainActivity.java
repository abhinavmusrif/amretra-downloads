package com.amretra.devnet;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

public final class MainActivity extends Activity {
    private IdentityStore identityStore;
    private MessageStore messageStore;
    private TextView identityValue;
    private TextView queueValue;
    private TextView diagnostics;
    private EditText payload;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        identityStore = new IdentityStore(this);
        messageStore = new MessageStore(this);
        maybeAskNotificationPermission();
        setContentView(buildUi());
        refresh();
    }

    private View buildUi() {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(Color.rgb(245, 247, 250));

        LinearLayout root = column(24);
        root.setPadding(dp(22), dp(28), dp(22), dp(32));
        scroll.addView(root);

        TextView eyebrow = text("DEVNET · ALPHA NODE", 12, true);
        eyebrow.setLetterSpacing(0.14f);
        root.addView(eyebrow);

        TextView title = text("Local-first connectivity, without pretending the internet is always there.", 28, true);
        title.setPadding(0, dp(8), 0, dp(8));
        root.addView(title);

        TextView intro = text("This build establishes the trustworthy local substrate first: persistent node identity, a loopback control plane, a durable outbound queue and explicit diagnostics.", 15, false);
        intro.setTextColor(Color.rgb(75, 85, 99));
        root.addView(intro);

        root.addView(card("NODE IDENTITY", identityValue = valueText()));
        root.addView(card("OUTBOUND QUEUE", queueValue = valueText()));

        LinearLayout controls = row();
        Button start = button("Start node");
        start.setOnClickListener(v -> {
            Intent i = new Intent(this, DevnetService.class);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i); else startService(i);
            diagnostics.setText("Control plane requested on 127.0.0.1:" + DevnetService.PORT + ".");
        });
        Button stop = button("Stop node");
        stop.setOnClickListener(v -> {
            stopService(new Intent(this, DevnetService.class));
            diagnostics.setText("Local control plane stopped.");
        });
        controls.addView(start, weight());
        controls.addView(space());
        controls.addView(stop, weight());
        root.addView(controls);

        payload = new EditText(this);
        payload.setHint("Queue a local message payload");
        payload.setMinLines(2);
        payload.setGravity(Gravity.TOP);
        payload.setBackgroundColor(Color.WHITE);
        payload.setPadding(dp(14), dp(12), dp(14), dp(12));
        LinearLayout.LayoutParams payloadParams = new LinearLayout.LayoutParams(-1, -2);
        payloadParams.setMargins(0, dp(18), 0, dp(10));
        root.addView(payload, payloadParams);

        Button enqueue = button("Queue message");
        enqueue.setOnClickListener(v -> {
            String text = payload.getText().toString().trim();
            if (text.isEmpty()) text = "hello from devnet alpha";
            String id = messageStore.enqueue(text, 60L * 60L * 1000L);
            payload.setText("");
            diagnostics.setText("Queued " + id + ". Peer transport remains intentionally disabled until authenticated QUIC/libp2p is wired.");
            refresh();
        });
        root.addView(enqueue);

        Button refresh = button("Refresh diagnostics");
        LinearLayout.LayoutParams refreshParams = new LinearLayout.LayoutParams(-1, -2);
        refreshParams.setMargins(0, dp(10), 0, 0);
        refresh.setLayoutParams(refreshParams);
        refresh.setOnClickListener(v -> refresh());
        root.addView(refresh);

        TextView transportTitle = text("PEER TRANSPORT", 12, true);
        transportTitle.setLetterSpacing(0.12f);
        LinearLayout.LayoutParams transportTitleParams = new LinearLayout.LayoutParams(-1, -2);
        transportTitleParams.setMargins(0, dp(24), 0, dp(6));
        root.addView(transportTitle, transportTitleParams);

        TextView blocked = text("BLOCKED BY DESIGN\nAuthenticated QUIC/libp2p + mutual-TLS compatibility is not implemented in this alpha. No UDP or cloud relay is masquerading as Devnet peer networking.", 14, false);
        blocked.setTextColor(Color.rgb(120, 53, 15));
        blocked.setBackgroundColor(Color.rgb(255, 247, 237));
        blocked.setPadding(dp(14), dp(14), dp(14), dp(14));
        root.addView(blocked);

        diagnostics = text("", 13, false);
        diagnostics.setTextIsSelectable(true);
        diagnostics.setTextColor(Color.rgb(55, 65, 81));
        LinearLayout.LayoutParams diagParams = new LinearLayout.LayoutParams(-1, -2);
        diagParams.setMargins(0, dp(18), 0, 0);
        root.addView(diagnostics, diagParams);

        return scroll;
    }

    private void refresh() {
        IdentityStore.IdentityStatus identity = identityStore.ensureIdentity();
        identityValue.setText(identity.ready ? identity.nodeId : "NOT READY · " + identity.detail);
        queueValue.setText(messageStore.pendingCount() + " queued · store-and-forward pending transport");
        diagnostics.setText(
                "Control plane: 127.0.0.1:" + DevnetService.PORT + "\n" +
                "Endpoints: GET /health, GET /identity, GET /messages, POST /messages\n" +
                "Discovery: bounded candidate model planned, not broadcasting in this alpha\n" +
                "Namespace: .iz treated as an application namespace, not public DNS\n" +
                "Consensus: intentionally outside private profiles, conversations and AI state");
    }

    private void maybeAskNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 44);
        }
    }

    private LinearLayout card(String label, TextView value) {
        LinearLayout card = column(6);
        card.setBackgroundColor(Color.WHITE);
        card.setPadding(dp(16), dp(14), dp(16), dp(14));
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-1, -2);
        p.setMargins(0, dp(16), 0, 0);
        card.setLayoutParams(p);
        TextView l = text(label, 11, true);
        l.setLetterSpacing(0.12f);
        l.setTextColor(Color.rgb(107, 114, 128));
        card.addView(l);
        card.addView(value);
        return card;
    }

    private TextView valueText() {
        TextView t = text("…", 15, true);
        t.setTextIsSelectable(true);
        return t;
    }

    private Button button(String label) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        return b;
    }

    private TextView text(String value, int sp, boolean bold) {
        TextView t = new TextView(this);
        t.setText(value);
        t.setTextSize(sp);
        t.setTextColor(Color.rgb(17, 24, 39));
        if (bold) t.setTypeface(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD);
        return t;
    }

    private LinearLayout column(int gapIgnored) {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        return l;
    }

    private LinearLayout row() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-1, -2);
        p.setMargins(0, dp(16), 0, 0);
        l.setLayoutParams(p);
        return l;
    }

    private LinearLayout.LayoutParams weight() {
        return new LinearLayout.LayoutParams(0, -2, 1f);
    }

    private View space() {
        View v = new View(this);
        v.setLayoutParams(new LinearLayout.LayoutParams(dp(10), 1));
        return v;
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    @Override
    protected void onDestroy() {
        if (messageStore != null) messageStore.close();
        super.onDestroy();
    }
}
