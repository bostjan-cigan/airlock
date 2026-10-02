# sample-java-notes

The notes API in Java 21 (the JDK's HTTP server, JDBC, Jedis, JUnit 5), built with Maven,
with Postgres and Redis from `compose.yaml`.

**What it tests:** Java detection from `pom.xml` (`maven.compiler.release` 21). There's
no Maven wrapper, so AIrlock installs Maven itself. It's also a heavy stack.

**What AIrlock should detect:**
- Tools: Java 21 and Maven, installed with mise
- Allowed hosts: `repo.maven.apache.org`, `repo1.maven.org` and the Gradle hosts
- Caches: the Maven repository (`~/.m2`) on the project's cache volume
- Size: automatic, 8 GB ("auto, Java")

**Prompt:**
> Run `mvn -q test` and report the output. Then add `DELETE /notes/{id}` (204, or 404 if
> missing; invalidate the cache), with a test. Commit.

**Pass criteria:** `java -version` is 21 and `mvn -v` works, dependencies download without
allowing any host, and the tests pass.
