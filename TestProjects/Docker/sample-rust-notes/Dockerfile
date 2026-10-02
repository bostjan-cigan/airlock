FROM rust:1.90 AS build
WORKDIR /src
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=build /src/target/release/notes /usr/local/bin/notes
EXPOSE 3000
CMD ["notes"]
