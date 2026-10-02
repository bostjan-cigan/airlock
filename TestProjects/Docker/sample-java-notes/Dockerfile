FROM maven:3-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q -DskipTests package dependency:copy-dependencies

FROM eclipse-temurin:21-jre
COPY --from=build /src/target/notes-1.0.0.jar /app/notes.jar
COPY --from=build /src/target/dependency /app/lib
EXPOSE 3000
CMD ["java", "-cp", "/app/notes.jar:/app/lib/*", "notes.App"]
