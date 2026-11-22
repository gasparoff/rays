;; Light System's headless adapter to the real Beat Link library bundled with BLT.
;; No BLT UI, Carabiner, metadata downloads, playback commands or master takeover.
(require '[cheshire.core :as json])
(import '[org.deepsymmetry.beatlink DeviceFinder DeviceAnnouncementListener
          VirtualCdj BeatFinder BeatListener CdjStatus])
(def output-lock (Object.))
(def alive (atom true))
(def finder (DeviceFinder/getInstance))
(def player (VirtualCdj/getInstance))
(def beats (BeatFinder/getInstance))
(defn emit [m]
  (locking output-lock
    (println (str "LSBLT " (json/generate-string (assoc m :timestamp (/ (System/currentTimeMillis) 1000.0)))))
    (flush)))
(defn stop-helper []
  (when (compare-and-set! alive true false)
    (try (.stop player) (catch Throwable _))
    (try (.stop beats) (catch Throwable _))
    (try (.stop finder) (catch Throwable _))))
(.addShutdownHook (Runtime/getRuntime) (Thread. ^Runnable stop-helper))
;; Parent owns stdin. Closing or crashing the GUI must not leave a hidden JVM alive.
(doto (Thread. ^Runnable (fn []
                         (try (while (not= -1 (.read System/in))) (catch Throwable _))
                         ;; A library shutdown hook must not orphan the helper if
                         ;; a network interface disappears during socket cleanup.
                         (doto (Thread. ^Runnable (fn [] (Thread/sleep 2500) (.halt (Runtime/getRuntime) 0)))
                           (.setDaemon true) (.start))
                         (stop-helper)
                         (System/exit 0)))
  (.setDaemon true) (.setName "LightSystem-parent-watch") (.start))
(.setDeviceName player "Light System")
(.addDeviceAnnouncementListener finder
  (reify DeviceAnnouncementListener
    (deviceFound [_ d]
      (emit {:type "device" :deck (.getDeviceNumber d) :name (.getDeviceName d) :present true}))
    (deviceLost [_ d]
      (emit {:type "device" :deck (.getDeviceNumber d) :name (.getDeviceName d) :present false}))))
(.addBeatListener beats
  (reify BeatListener
    (newBeat [_ b]
      (try
        (let [status (when (.isRunning player) (.getLatestStatusFor player b))
              fresh (and status (< (- (System/nanoTime) (.getTimestamp status)) 1500000000))
              playing (and fresh (instance? CdjStatus status) (.isPlaying ^CdjStatus status))
              master (and fresh (.isTempoMaster b))]
          (emit {:type "beat" :deck (.getDeviceNumber b) :name (.getDeviceName b)
                 :bpm (.getEffectiveTempo b) :beat (.getBeatWithinBar b)
                 :master (boolean master) :playing (boolean playing)}))
        (catch Throwable _)))))
(try
  (.start finder)
  (.start beats)
  (emit {:type "ready" :state "searching" :version "Beat Link 7.4.0"})
  (let [last-state (atom nil) last-tick (atom 0)]
    (while @alive
      (try
        ;; Start only after discovery; no console means an immediate idle state.
        (when (and (not (.isRunning player)) (seq (.getCurrentDevices finder)))
          (when-not (.start player)
            (emit {:type "status" :state "network"})))
        (let [state (if (.isRunning player) "online" "searching") now (System/currentTimeMillis)]
          (when (or (not= state @last-state) (> (- now @last-tick) 2000))
            (emit {:type "status" :state state})
            (reset! last-state state)
            (reset! last-tick now)))
        (Thread/sleep 250)
        (catch Throwable e
          (emit {:type "error" :message (or (.getMessage e) (.getName (class e)))})
          (Thread/sleep 2000)))))
  (catch Throwable e
    (emit {:type "error" :message (or (.getMessage e) (.getName (class e)))})
    (stop-helper)
    (System/exit 1)))
