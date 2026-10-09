package com.amretra.devnet;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class DevnetService extends Service {
    static final int PORT = 8787;
    private static final String CHANNEL = "devnet_node";
    private static final int NOTIFICATION_ID = 8787;
    private static final Pattern PAYLOAD = Pattern.compile("\\\"payload\\\"\\s*:\\s*\\\"(.*?)\\\"");

    private final ExecutorService acceptor = Executors.newSingleThreadExecutor();
    private final ExecutorService clients = Executors.newCachedThreadPool();
    private volatile boolean running;
    private volatile ServerSocket serverSocket;
    private MessageStore messageStore;
    private IdentityStore identityStore;

    @Override
    public void onCreate() {
        super.onCreate();
        messageStore = new MessageStore(this);
        identityStore = new IdentityStore(this);
        createChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        IdentityStore.IdentityStatus identity = identityStore.ensureIdentity();
        String note = identity.ready ? identity.nodeId : "identity blocked";
        Notification notification = new Notification.Builder(this, CHANNEL)
                .setContentTitle("Devnet node")
                .setContentText("Local control plane · " + note)
                .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                .setOngoing(true)
                .build();
        startForeground(NOTIFICATION_ID, notification);
        startLocalControlPlane();
        return START_STICKY;
    }

    private synchronized void startLocalControlPlane() {
        if (running) return;
        running = true;
        acceptor.submit(() -> {
            try (ServerSocket socket = new ServerSocket(PORT, 32, InetAddress.getByName("127.0.0.1"))) {
                serverSocket = socket;
                while (running) {
                    Socket client = socket.accept();
                    clients.submit(() -> handle(client));
                }
            } catch (Exception e) {
                running = false;
            } finally {
                serverSocket = null;
            }
        });
    }

    private void handle(Socket socket) {
        try (Socket s = socket;
             BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
             BufferedWriter out = new BufferedWriter(new OutputStreamWriter(s.getOutputStream(), StandardCharsets.UTF_8))) {

            String requestLine = in.readLine();
            if (requestLine == null) return;
            String[] parts = requestLine.split(" ");
            String method = parts.length > 0 ? parts[0].toUpperCase(Locale.ROOT) : "";
            String path = parts.length > 1 ? parts[1] : "/";

            int contentLength = 0;
            String line;
            while ((line = in.readLine()) != null && !line.isEmpty()) {
                int colon = line.indexOf(':');
                if (colon > 0 && "content-length".equalsIgnoreCase(line.substring(0, colon).trim())) {
                    try { contentLength = Integer.parseInt(line.substring(colon + 1).trim()); } catch (NumberFormatException ignored) {}
                }
            }

            char[] bodyChars = new char[Math.max(0, Math.min(contentLength, 64 * 1024))];
            int offset = 0;
            while (offset < bodyChars.length) {
                int n = in.read(bodyChars, offset, bodyChars.length - offset);
                if (n < 0) break;
                offset += n;
            }
            String body = new String(bodyChars, 0, offset);

            if ("GET".equals(method) && "/health".equals(path)) {
                respond(out, 200, "{\"status\":\"ok\",\"controlPlane\":\"127.0.0.1:8787\",\"peerTransport\":\"disabled\"}");
            } else if ("GET".equals(method) && "/identity".equals(path)) {
                IdentityStore.IdentityStatus st = identityStore.ensureIdentity();
                String json = "{\"ready\":" + st.ready + ",\"nodeId\":\"" + MessageStore.json(st.nodeId == null ? "" : st.nodeId) + "\",\"detail\":\"" + MessageStore.json(st.detail) + "\"}";
                respond(out, st.ready ? 200 : 503, json);
            } else if ("GET".equals(method) && "/messages".equals(path)) {
                respond(out, 200, messageStore.recentJson(50));
            } else if ("POST".equals(method) && "/messages".equals(path)) {
                Matcher m = PAYLOAD.matcher(body);
                if (!m.find()) {
                    respond(out, 400, "{\"error\":\"expected JSON payload field\"}");
                } else {
                    String payload = m.group(1).replace("\\\"", "\"").replace("\\\\", "\\");
                    String id = messageStore.enqueue(payload, 60L * 60L * 1000L);
                    respond(out, 202, "{\"id\":\"" + id + "\",\"status\":\"QUEUED\",\"path\":\"NONE\"}");
                }
            } else {
                respond(out, 404, "{\"error\":\"not found\"}");
            }
        } catch (Exception ignored) {
        }
    }

    private static void respond(BufferedWriter out, int status, String body) throws Exception {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        String reason = status == 200 ? "OK" : status == 202 ? "Accepted" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : "Service Unavailable";
        out.write("HTTP/1.1 " + status + " " + reason + "\r\n");
        out.write("Content-Type: application/json; charset=utf-8\r\n");
        out.write("Content-Length: " + bytes.length + "\r\n");
        out.write("Cache-Control: no-store\r\n");
        out.write("Connection: close\r\n\r\n");
        out.write(body);
        out.flush();
    }

    private void createChannel() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager != null) {
            NotificationChannel channel = new NotificationChannel(CHANNEL, "Devnet node", NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("Devnet local node and control-plane state");
            manager.createNotificationChannel(channel);
        }
    }

    @Override
    public void onDestroy() {
        running = false;
        try { if (serverSocket != null) serverSocket.close(); } catch (Exception ignored) {}
        acceptor.shutdownNow();
        clients.shutdownNow();
        if (messageStore != null) messageStore.close();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
