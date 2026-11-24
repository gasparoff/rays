import org.deepsymmetry.beatlink.Beat;
import org.deepsymmetry.beatlink.BeatFinder;
import org.deepsymmetry.beatlink.CdjStatus;
import org.deepsymmetry.beatlink.DeviceAnnouncement;
import org.deepsymmetry.beatlink.DeviceAnnouncementListener;
import org.deepsymmetry.beatlink.DeviceFinder;
import org.deepsymmetry.beatlink.DeviceUpdate;
import org.deepsymmetry.beatlink.VirtualCdj;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicBoolean;

/** Headless adapter to the real Beat Link library. No Clojure, BLT UI, metadata
 * downloads, playback commands, or requests to become tempo master at runtime. */
public final class LightSystemBeatLink {
    private static final AtomicBoolean alive = new AtomicBoolean(true);
    private static final DeviceFinder finder = DeviceFinder.getInstance();
    private static final VirtualCdj player = VirtualCdj.getInstance();
    private static final BeatFinder beats = BeatFinder.getInstance();

    private static synchronized void emit(String fields) {
        System.out.println("LSBLT {" + fields + ",\"timestamp\":" + (System.currentTimeMillis() / 1000.0) + "}");
        System.out.flush();
    }

    /** JSON string quoting, including control characters from network device names. */
    private static String quote(String value) {
        if (value == null) return "\"\"";
        StringBuilder result = new StringBuilder(value.length() + 2).append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"': result.append("\\\""); break;
                case '\\': result.append("\\\\"); break;
                case '\n': result.append("\\n"); break;
                case '\r': result.append("\\r"); break;
                case '\t': result.append("\\t"); break;
                case '\b': result.append("\\b"); break;
                case '\f': result.append("\\f"); break;
                default:
                    if (c < 0x20 || Character.isSurrogate(c)) {
                        result.append("\\u");
                        String hex = Integer.toHexString(c);
                        for (int j = hex.length(); j < 4; j++) result.append('0');
                        result.append(hex);
                    } else result.append(c);
            }
        }
        return result.append('"').toString();
    }

    private static void stop() {
        if (alive.compareAndSet(true, false)) {
            try { player.stop(); } catch (Throwable ignored) { }
            try { beats.stop(); } catch (Throwable ignored) { }
            try { finder.stop(); } catch (Throwable ignored) { }
        }
    }

    private static Thread daemon(String name, Runnable action) {
        Thread thread = new Thread(action, name);
        thread.setDaemon(true);
        thread.start();
        return thread;
    }

    private static void watchParent() {
        daemon("LightSystem-parent-watch", () -> {
            try { while (System.in.read() != -1) { } } catch (IOException ignored) { }
            // A disappearing interface must not leave an orphan even if library cleanup blocks.
            daemon("LightSystem-exit-deadline", () -> {
                try { Thread.sleep(2500); } catch (InterruptedException ignored) { }
                Runtime.getRuntime().halt(0);
            });
            stop();
            System.exit(0);
        });
    }

    private static void announce(DeviceAnnouncement device, boolean present) {
        emit("\"type\":\"device\",\"deck\":" + device.getDeviceNumber() +
             ",\"name\":" + quote(device.getDeviceName()) + ",\"present\":" + present);
    }

    private static void beat(Beat beat) {
        try {
            DeviceUpdate status = player.isRunning() ? player.getLatestStatusFor(beat) : null;
            long age = status == null ? Long.MAX_VALUE : System.nanoTime() - status.getTimestamp();
            boolean fresh = age >= 0 && age < 1_500_000_000L;
            boolean playing = fresh && status instanceof CdjStatus && ((CdjStatus) status).isPlaying();
            boolean master = fresh && beat.isTempoMaster();
            double bpm = beat.getEffectiveTempo();
            if (!Double.isFinite(bpm)) return;
            emit("\"type\":\"beat\",\"deck\":" + beat.getDeviceNumber() +
                 ",\"name\":" + quote(beat.getDeviceName()) + ",\"bpm\":" + bpm +
                 ",\"beat\":" + beat.getBeatWithinBar() + ",\"master\":" + master +
                 ",\"playing\":" + playing);
        } catch (RuntimeException ignored) { }
    }

    private static void error(Throwable error) {
        String message = error.getMessage();
        emit("\"type\":\"error\",\"message\":" + quote(message == null ? error.getClass().getSimpleName() : message));
    }

    public static void main(String[] args) throws InterruptedException {
        if (args.length > 0 && args[0].equals("--protocol-test")) {
            emit("\"type\":\"device\",\"deck\":2,\"name\":" + quote("XDJ\"XZ\\\n\u0001 ☀" ) + ",\"present\":true");
            return;
        }
        Runtime.getRuntime().addShutdownHook(new Thread(LightSystemBeatLink::stop, "LightSystem-shutdown"));
        watchParent();
        player.setDeviceName("RAYS");
        if (args.length > 0 && args[0].equals("--memory-check")) {
            emit("\"type\":\"ready\",\"state\":\"self-test\",\"version\":\"Beat Link 7.4.0 Java adapter\"");
            while (alive.get()) Thread.sleep(250);
            return;
        }
        finder.addDeviceAnnouncementListener(new DeviceAnnouncementListener() {
            public void deviceFound(DeviceAnnouncement device) { announce(device, true); }
            public void deviceLost(DeviceAnnouncement device) { announce(device, false); }
        });
        beats.addBeatListener(LightSystemBeatLink::beat);
        try {
            finder.start();
            beats.start();
            emit("\"type\":\"ready\",\"state\":\"searching\",\"version\":\"Beat Link 7.4.0\"");
            String previous = null;
            long lastTick = 0;
            while (alive.get()) {
                try {
                    if (!player.isRunning() && !finder.getCurrentDevices().isEmpty()) {
                        if (!player.start()) emit("\"type\":\"status\",\"state\":\"network\"");
                    }
                    String state = player.isRunning() ? "online" : "searching";
                    long now = System.currentTimeMillis();
                    if (!state.equals(previous) || now - lastTick > 2000) {
                        emit("\"type\":\"status\",\"state\":" + quote(state));
                        previous = state;
                        lastTick = now;
                    }
                    Thread.sleep(250);
                } catch (Exception failure) {
                    error(failure);
                    Thread.sleep(2000);
                }
            }
        } catch (Exception failure) {
            error(failure);
            stop();
            System.exit(1);
        }
    }
}
