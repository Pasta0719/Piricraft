package jp.piricraft.check;

import net.kyori.adventure.text.Component;
import net.kyori.adventure.text.format.NamedTextColor;

import org.bukkit.Bukkit;
import org.bukkit.command.Command;
import org.bukkit.command.CommandSender;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.Listener;
import org.bukkit.event.player.PlayerJoinEvent;
import org.bukkit.event.player.PlayerQuitEvent;
import org.bukkit.plugin.java.JavaPlugin;
import org.bukkit.plugin.messaging.PluginMessageListener;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;


public class PiricraftCheckPlugin
        extends JavaPlugin
        implements Listener,
                   PluginMessageListener {

    private CheckAutoUpdater autoUpdater;

    private static final String CHANNEL =
            "piricraft:mod_hashes";


    // ========================================================
    // Launcher authentication
    // ========================================================

    private static final String
            LAUNCH_HMAC_KEY_BASE64 =
            "rYa95rabnEFa1J7oFi/rk9qipyZpwHFDNRqiI60xbIo=";

    // チケット有効期限の既定値。
    // config.yml の launcher-auth.ticket-max-age-hours で変更可能。
    private static final long
            DEFAULT_LAUNCH_TICKET_MAX_AGE_HOURS =
            24L;

    // PC時計の多少のズレを許容。
    private static final long
            FUTURE_CLOCK_TOLERANCE_SECONDS =
            5L * 60L;

    // 接続済みID保持時間の既定値。
    // config.yml の launcher-auth.used-ticket-retention-hours で変更可能。
    private static final long
            DEFAULT_USED_LAUNCH_RETENTION_HOURS =
            24L;

    private static final String
            LAUNCH_TICKET_EXPIRED_REASON =
            "PiriCraftの起動認証の有効期限が切れました（クライアント構成エラーではありません）。Minecraftを終了し、PiriCraft Launcherから起動し直してください";


    // ========================================================
    // Allowed MOD SHA-256
    // ========================================================

    private static final Set<String>
            ALLOWED_HASHES =
            Set.of(
                "9A19CEC1294B1BC708392A08E6926DCB85D7378EC5AD909A4B6FCB8BC3BFEAA2",
                "A61A10F730AB8AA45FF42486EE65699E6E51C28A0C168DEB161E7D4029473AA3",
                "B5AD39A6CB113CA0A1765F06689F9F4B29CCD0C81247DE90B06C42F5DA1092F5",
                "3176AE9F05ED0000CF8ED1A4EFFD0CF349556B54686EF02A03CBB88492235002",
                "4A19B5E2038D440C42009E4E9A35E4C2B019EFA14BD33ADCFAAE134A6921E328",
                "0410D7205FAE31007450DB70C3FF00A598CB0C38B330D2E5DF516353037DF54A",
                "868A31D5E7E66745CFAA33E75E1B036291B03761404F6B1F11777FCDD734A3E0",
                "E04599514D88E41765F710EEBA59E3814909833396BC11B977F48FC2E7E50353",
                "5CBEA2A6BF5A92BF536D5EEBE1530C42AAFB46FCBC11E72271D096DEBF302F6D",
                "8649C93BE0CE20655742ADB24BAC097A9AEEC50B8C1BC8ED78BFE1DA7636E8FA",
                "2C31200D1F5DE6A3CF5EDC4C3D39200636E1E060C4B548DCF8249EF487660323",
                "81560F1A99D58C3E67F12070F675263557EFAE8CCFF64656112346030439CDCC",
                "322DC5AFD40A8E007D19CDD21779AA758464E6F8C31AF2EFEABD243F237008C8"
            );

    private static final Map<UUID, String>
            ALWAYS_ALLOWED_PLAYERS =
            Map.of(
                UUID.fromString(
                        "8805daa2-999a-4cb8-8689-a2b3b17b9ffc"),
                "くもり",
                UUID.fromString(
                        "a227f3fa-b52d-4bfd-888e-46d15d583d78"),
                "ぱすた"
            );


    // ========================================================
    // Per-player verification
    // ========================================================

    private final Map<UUID, List<String>>
            receivedHashes =
            new ConcurrentHashMap<>();

    private final Map<UUID, String>
            receivedLaunchTickets =
            new ConcurrentHashMap<>();

    private final Set<UUID>
            invalidClients =
            ConcurrentHashMap.newKeySet();

    private final Set<UUID>
            authenticatedClients =
            ConcurrentHashMap.newKeySet();

    private final Set<UUID>
            verificationFinished =
            ConcurrentHashMap.newKeySet();


    // Launch ID -> time consumed
    private final Map<String, Long>
            usedLaunchIds =
            new ConcurrentHashMap<>();


    @Override
    public void onEnable() {

        saveDefaultConfig();

        if (getConfig().getBoolean("auto-update.enabled", true)) {
            try {
                Properties release = new Properties();
                try (var stream = getResource("check-release.properties")) {
                    if (stream == null) throw new IllegalStateException("Check release metadata missing");
                    release.load(stream);
                }
                // Paper may load a remapped copy; updates must target the original plugins JAR.
                var installed = new java.io.File(getDataFolder().getParentFile(), getFile().getName());
                autoUpdater = new CheckAutoUpdater(installed.toPath(),
                        getServer().getUpdateFolderFile().toPath(), getDataFolder().toPath(),
                        release.getProperty("version"), message -> getLogger().info(message));
                autoUpdater.start(getConfig().getLong("auto-update.check-interval-minutes", 5));
                getLogger().info("Check自動更新: 有効（更新は次回のサーバー再起動時に適用）");
            } catch (Exception e) {
                getLogger().warning("Check自動更新を開始できませんでした: " + e.getMessage());
            }
        }

        Bukkit.getPluginManager()
                .registerEvents(
                        this,
                        this);

        getServer()
                .getMessenger()
                .registerIncomingPluginChannel(
                        this,
                        CHANNEL,
                        this
                );

        getLogger().info(
                "PiricraftCheck enabled");

        getLogger().info(
                "Listening channel: " +
                CHANNEL);

        getLogger().info(
                "Allowed MOD count: " +
                ALLOWED_HASHES.size());

        getLogger().info(
                "Launcher authentication: ENABLED");

        getLogger().info(
                "Launcher ticket max age: "
                +
                launchTicketMaxAgeHours()
                +
                " hours");

        getLogger().info(
                "Kick on NG: " +
                getConfig().getBoolean(
                        "kick-on-ng",
                        false
                ));
    }


    @Override
    public void onDisable() {

        if (autoUpdater != null) autoUpdater.close();

        getServer()
                .getMessenger()
                .unregisterIncomingPluginChannel(
                        this,
                        CHANNEL
                );

        receivedHashes.clear();
        receivedLaunchTickets.clear();
        invalidClients.clear();
        authenticatedClients.clear();
        verificationFinished.clear();
        usedLaunchIds.clear();
    }


    @EventHandler
    public void onJoin(
            PlayerJoinEvent event) {

        Player player =
                event.getPlayer();

        UUID uuid =
                player.getUniqueId();

        receivedHashes.remove(uuid);
        receivedLaunchTickets.remove(uuid);
        invalidClients.remove(uuid);
        authenticatedClients.remove(uuid);
        verificationFinished.remove(uuid);

        cleanupUsedLaunchIds();


        // MinecraftがサーバーへJOINした後の通信待ち。
        // PCの起動速度とは無関係。
        Bukkit.getScheduler()
                .runTaskLater(
                        this,
                        () -> {

                            if (!player.isOnline()) {
                                return;
                            }

                            if (!verificationFinished
                                    .contains(uuid)) {

                                getLogger().warning(
                                        "[PiricraftCheck] Verification timeout: "
                                        +
                                        player.getName());

                                handleNg(
                                        player,
                                        "PiriCraft認証情報を受信できませんでした"
                                );
                            }
                        },
                        100L
                );
    }


    @EventHandler
    public void onQuit(
            PlayerQuitEvent event) {

        UUID uuid =
                event.getPlayer()
                        .getUniqueId();

        receivedHashes.remove(uuid);
        receivedLaunchTickets.remove(uuid);
        invalidClients.remove(uuid);
        authenticatedClients.remove(uuid);
        verificationFinished.remove(uuid);
    }


    @Override
    public void onPluginMessageReceived(
            String channel,
            Player player,
            byte[] message) {

        if (!CHANNEL.equals(
                channel)) {
            return;
        }

        final String value;

        try {

            value =
                    decodeMinecraftString(
                            message);
        }
        catch (Exception e) {

            invalidClients.add(
                    player.getUniqueId());

            getLogger().warning(
                    "[PiricraftCheck] Invalid payload from "
                    +
                    player.getName());

            return;
        }

        UUID uuid =
                player.getUniqueId();

        // チケットそのものをサーバーログへ出さない。
        String logValue =
                value.startsWith(
                        "LAUNCH:")
                        ? "LAUNCH:[REDACTED]"
                        : value;

        getLogger().info(
                "[PiricraftCheck] Payload from "
                +
                player.getName()
                +
                ": "
                +
                logValue);


        // ====================================================
        // BEGIN
        // ====================================================

        if ("BEGIN".equals(
                value)) {

            receivedHashes.put(
                    uuid,
                    new ArrayList<>());

            receivedLaunchTickets.remove(
                    uuid);

            invalidClients.remove(
                    uuid);

            verificationFinished.remove(
                    uuid);

            return;
        }


        // ====================================================
        // LAUNCH
        // ====================================================

        if (value.startsWith(
                "LAUNCH:")) {

            if (!receivedHashes.containsKey(
                    uuid)) {

                invalidClients.add(
                        uuid);

                return;
            }

            String ticket =
                    value.substring(
                            "LAUNCH:".length())
                            .trim();

            if (ticket.isEmpty()
                    ||
                    ticket.length() > 512) {

                invalidClients.add(
                        uuid);

                return;
            }

            // 二重送信も不正扱い。
            if (receivedLaunchTickets.putIfAbsent(
                    uuid,
                    ticket) != null) {

                invalidClients.add(
                        uuid);
            }

            return;
        }


        // ====================================================
        // INVALID
        // ====================================================

        if (value.startsWith(
                "INVALID:")) {

            invalidClients.add(
                    uuid);

            getLogger().warning(
                    "[PiricraftCheck] Client reported "
                    +
                    value);

            return;
        }


        // ====================================================
        // HASH
        // ====================================================

        if (value.startsWith(
                "HASH:")) {

            List<String> hashes =
                    receivedHashes.get(
                            uuid);

            if (hashes == null) {

                invalidClients.add(
                        uuid);

                return;
            }

            String hash =
                    value
                            .substring(
                                    "HASH:".length())
                            .trim()
                            .toUpperCase(
                                    Locale.ROOT);

            if (!hash.matches(
                    "[0-9A-F]{64}")) {

                invalidClients.add(
                        uuid);

                return;
            }

            hashes.add(
                    hash);

            return;
        }


        // ====================================================
        // END
        // ====================================================

        if ("END".equals(
                value)) {

            try {
                validatePlayer(
                        player);
            }
            finally {

                verificationFinished.add(
                        uuid);

                receivedHashes.remove(
                        uuid);

                receivedLaunchTickets.remove(
                        uuid);

                invalidClients.remove(
                        uuid);
            }

            return;
        }


        invalidClients.add(
                uuid);
    }


    // ========================================================
    // Full verification
    // ========================================================

    private void validatePlayer(
            Player player) {

        UUID uuid =
                player.getUniqueId();

        getLogger().info(
                "================================");

        getLogger().info(
                "[PiricraftCheck] Player: "
                +
                player.getName());


        // ====================================================
        // Basic client state
        // ====================================================

        if (invalidClients.contains(
                uuid)) {

            handleNg(
                    player,
                    "クライアントから不正な認証情報を受信しました"
            );

            return;
        }


        // ====================================================
        // Launcher ticket
        // ====================================================

        String ticket =
                receivedLaunchTickets.get(
                        uuid);

        if (ticket == null) {

            handleNg(
                    player,
                    "PiriCraft Launcherから起動されていません"
            );

            return;
        }

        final String launchId;

        try {

            launchId =
                    validateLaunchTicket(
                            player,
                            ticket);
        }
        catch (Exception e) {

            getLogger().warning(
                    "[PiricraftCheck] Launch ticket NG: "
                    +
                    e.getMessage());

            String reason =
                    "expired".equals(
                            e.getMessage())
                            ? LAUNCH_TICKET_EXPIRED_REASON
                            : "PiriCraft Launcherの起動認証に失敗しました";

            handleNg(
                    player,
                    reason
            );

            return;
        }

        cleanupUsedLaunchIds();


        // ====================================================
        // MOD hashes
        // ====================================================

        List<String> hashes =
                receivedHashes.get(
                        uuid);

        if (hashes == null) {

            handleNg(
                    player,
                    "MOD情報を受信できませんでした"
            );

            return;
        }

        getLogger().info(
                "Received MOD count: "
                +
                hashes.size());

        Set<String> received =
                new HashSet<>(
                        hashes);

        if (hashes.size()
                !=
                ALLOWED_HASHES.size()) {

            handleNg(
                    player,
                    "MOD数が正規構成と一致しません"
            );

            return;
        }

        if (received.size()
                !=
                hashes.size()) {

            handleNg(
                    player,
                    "MOD SHA一覧に重複があります"
            );

            return;
        }

        if (!received.equals(
                ALLOWED_HASHES)) {

            Set<String> missing =
                    new HashSet<>(
                            ALLOWED_HASHES);

            missing.removeAll(
                    received);

            Set<String> extra =
                    new HashSet<>(
                            received);

            extra.removeAll(
                    ALLOWED_HASHES);

            getLogger().warning(
                    "Missing SHA: "
                    +
                    missing);

            getLogger().warning(
                    "Extra SHA: "
                    +
                    extra);

            handleNg(
                    player,
                    "MOD構成が一致しません"
            );

            return;
        }


        // ====================================================
        // Record launch ID atomically.
        // The ticket is bound to the authenticated Minecraft UUID,
        // so reuse by the same UUID is a valid server reconnect.
        // ====================================================

        long now =
                System.currentTimeMillis()
                        / 1000L;

        Long alreadyUsed =
                usedLaunchIds.putIfAbsent(
                        launchId,
                        now);

        if (alreadyUsed != null) {

            getLogger().info(
                    "Launcher ticket reused by the same UUID: reconnect accepted"
            );
        }


        // ====================================================
        // OK
        // ====================================================

        authenticatedClients.add(
                uuid);

        getLogger().info(
                alreadyUsed == null
                        ? "Launcher ticket: OK"
                        : "Launcher ticket: OK (reconnect)");

        getLogger().info(
                "MOD hashes: OK");

        getLogger().info(
                "Piricraft Client: OK");

        player.sendMessage(
                Component.text(
                        "PiriCraft認証が完了しました。"
                )
        );

        getLogger().info(
                "================================");
    }


    // ========================================================
    // Launcher ticket validation
    //
    // v1.UUID.issuedAt.launchId.hmac
    // ========================================================

    private String validateLaunchTicket(
            Player player,
            String ticket)
            throws Exception {

        String[] parts =
                ticket.split(
                        "\\.",
                        -1);

        if (parts.length != 5) {
            throw new IllegalArgumentException(
                    "field count");
        }

        if (!"v1".equals(
                parts[0])) {

            throw new IllegalArgumentException(
                    "version");
        }

        String ticketUuid =
                parts[1]
                        .toLowerCase(
                                Locale.ROOT);

        if (!ticketUuid.matches(
                "[0-9a-f]{32}")) {

            throw new IllegalArgumentException(
                    "uuid");
        }

        String playerUuid =
                player
                        .getUniqueId()
                        .toString()
                        .replace(
                                "-",
                                "")
                        .toLowerCase(
                                Locale.ROOT);

        if (!ticketUuid.equals(
                playerUuid)) {

            throw new IllegalArgumentException(
                    "uuid mismatch");
        }

        long issuedAt;

        try {

            issuedAt =
                    Long.parseLong(
                            parts[2]);
        }
        catch (NumberFormatException e) {

            throw new IllegalArgumentException(
                    "issuedAt");
        }

        String launchId =
                parts[3];

        if (!launchId.matches(
                "[A-Za-z0-9_-]{20,80}")) {

            throw new IllegalArgumentException(
                    "launchId");
        }

        String signatureHex =
                parts[4];

        if (!signatureHex.matches(
                "[0-9A-Fa-f]{64}")) {

            throw new IllegalArgumentException(
                    "signature");
        }

        long now =
                System.currentTimeMillis()
                        / 1000L;

        if (issuedAt >
                now +
                FUTURE_CLOCK_TOLERANCE_SECONDS) {

            throw new IllegalArgumentException(
                    "future timestamp");
        }

        if (now - issuedAt >
                launchTicketMaxAgeHours()
                *
                60L
                *
                60L) {

            throw new IllegalArgumentException(
                    "expired");
        }

        String signedData =
                "v1|"
                +
                ticketUuid
                +
                "|"
                +
                issuedAt
                +
                "|"
                +
                launchId;

        byte[] key =
                Base64
                        .getDecoder()
                        .decode(
                                LAUNCH_HMAC_KEY_BASE64);

        Mac mac =
                Mac.getInstance(
                        "HmacSHA256");

        mac.init(
                new SecretKeySpec(
                        key,
                        "HmacSHA256"));

        byte[] expectedSignature =
                mac.doFinal(
                        signedData.getBytes(
                                StandardCharsets.UTF_8));

        byte[] actualSignature;

        try {

            actualSignature =
                    HexFormat
                            .of()
                            .parseHex(
                                    signatureHex);
        }
        catch (Exception e) {

            throw new IllegalArgumentException(
                    "signature encoding");
        }

        if (!MessageDigest.isEqual(
                expectedSignature,
                actualSignature)) {

            throw new IllegalArgumentException(
                    "signature mismatch");
        }

        return launchId;
    }


    // ========================================================
    // Accepted Launch ID cleanup
    // ========================================================

    private void cleanupUsedLaunchIds() {

        long now =
                System.currentTimeMillis()
                        / 1000L;

        usedLaunchIds
                .entrySet()
                .removeIf(
                        entry ->
                                now
                                -
                                entry.getValue()
                                >
                                usedTicketRetentionHours()
                                *
                                60L
                                *
                                60L
                );
    }


    private long launchTicketMaxAgeHours() {

        return positiveHours(
                "launcher-auth.ticket-max-age-hours",
                DEFAULT_LAUNCH_TICKET_MAX_AGE_HOURS
        );
    }


    private long usedTicketRetentionHours() {

        return positiveHours(
                "launcher-auth.used-ticket-retention-hours",
                DEFAULT_USED_LAUNCH_RETENTION_HOURS
        );
    }


    private long positiveHours(
            String path,
            long defaultValue) {

        long value =
                getConfig().getLong(
                        path,
                        defaultValue
                );

        return Math.max(
                1L,
                value
        );
    }


    // ========================================================
    // Fabric PacketCodecs.STRING decoder
    // ========================================================

    private String decodeMinecraftString(
            byte[] data) {

        int value = 0;
        int position = 0;
        int index = 0;

        while (true) {

            if (index >=
                    data.length) {

                throw new IllegalArgumentException(
                        "VarInt truncated");
            }

            int current =
                    data[index++]
                    &
                    0xFF;

            value |=
                    (current & 0x7F)
                    <<
                    position;

            if ((current & 0x80)
                    ==
                    0) {

                break;
            }

            position +=
                    7;

            if (position >=
                    35) {

                throw new IllegalArgumentException(
                        "VarInt too large");
            }
        }

        if (value < 0
                ||
                index + value >
                data.length) {

            throw new IllegalArgumentException(
                    "Invalid string length");
        }

        return new String(
                data,
                index,
                value,
                StandardCharsets.UTF_8
        );
    }


    // ========================================================
    // NG
    // ========================================================

    private void handleNg(
            Player player,
            String reason) {

        boolean launchTicketExpired =
                LAUNCH_TICKET_EXPIRED_REASON.equals(
                        reason);

        String clientStatus =
                launchTicketExpired
                        ? "[PiricraftCheck] PiriCraft起動認証: 期限切れ"
                        : "[PiricraftCheck] Piricraft Client: NG";

        getLogger().warning(
                launchTicketExpired
                        ? "PiriCraft launcher authentication: EXPIRED"
                        : "Piricraft Client: NG");

        getLogger().warning(
                "Reason: "
                +
                reason);

        UUID uuid =
                player.getUniqueId();

        String alwaysAllowedName =
                ALWAYS_ALLOWED_PLAYERS.get(
                        uuid);

        if (alwaysAllowedName != null) {

            invalidClients.remove(
                    uuid);

            authenticatedClients.add(
                    uuid);

            verificationFinished.add(
                    uuid);

            player.sendMessage(
                    Component.text(
                            clientStatus,
                            launchTicketExpired
                                    ? NamedTextColor.YELLOW
                                    : NamedTextColor.WHITE
                    )
            );

            player.sendMessage(
                    Component.text(
                            "理由: "
                            +
                            reason
                    )
            );

            player.sendMessage(
                    Component.text(
                            "...でも、"
                            +
                            alwaysAllowedName
                            +
                            "なのでOK！！！",
                            NamedTextColor.YELLOW
                    )
            );

            getLogger().info(
                    "Always-allowed player accepted: "
                    +
                    player.getName());

            getLogger().info(
                    "================================");

            return;
        }

        boolean kickOnNg =
                getConfig()
                        .getBoolean(
                                "kick-on-ng",
                                false
                        );

        if (kickOnNg) {

            getLogger().warning(
                    "Kicking player: "
                    +
                    player.getName());

            player.kick(
                    Component.text(
                            (launchTicketExpired
                                    ? "PiriCraft起動認証: 期限切れ\n\n"
                                    : "Piricraft Client: NG\n\n")
                            +
                            "理由: "
                            +
                            reason
                    )
            );
        }
        else {

            player.sendMessage(
                    Component.text(
                            clientStatus,
                            launchTicketExpired
                                    ? NamedTextColor.YELLOW
                                    : NamedTextColor.WHITE
                    )
            );

            player.sendMessage(
                    Component.text(
                            "理由: "
                            +
                            reason
                    )
            );
        }

        getLogger().info(
                "================================");
    }


    // ========================================================
    // Command
    // ========================================================

    @Override
    public boolean onCommand(
            CommandSender sender,
            Command command,
            String label,
            String[] args) {

        if (!command
                .getName()
                .equalsIgnoreCase(
                        "piricraftcheck")) {

            return false;
        }

        if (args.length == 1
                &&
                args[0]
                        .equalsIgnoreCase(
                                "toggle")) {

            boolean current =
                    getConfig()
                            .getBoolean(
                                    "kick-on-ng",
                                    false
                            );

            boolean next =
                    !current;

            getConfig().set(
                    "kick-on-ng",
                    next);

            saveConfig();

            sender.sendMessage(
                    Component.text(
                            "[PiricraftCheck] NG Kick: "
                            +
                            (next
                                    ? "ON"
                                    : "OFF")
                    )
            );

            return true;
        }

        sender.sendMessage(
                Component.text(
                        "/piricraftcheck toggle"
                )
        );

        return true;
    }
}
