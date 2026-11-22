;; Build-time only: the bundled JRE contains jdk.compiler. No Clojure is loaded
;; by the application or its console helper at runtime.
(let [compiler (javax.tools.ToolProvider/getSystemJavaCompiler)
      [source output] *command-line-args*]
  (when-not compiler (throw (IllegalStateException. "Bundled runtime must include jdk.compiler")))
  (System/exit (.run compiler nil System/out System/err
                     (into-array String ["--release" "11" "-encoding" "UTF-8"
                                         "-classpath" (System/getProperty "java.class.path")
                                         "-d" output source]))))
