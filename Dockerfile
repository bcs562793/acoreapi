FROM dart:stable AS build
WORKDIR /app
COPY pubspec.yaml .
RUN dart pub get
COPY . .
RUN mkdir -p bin && dart compile exe main.dart -o bin/listener

FROM debian:bullseye-slim
COPY --from=build /app/bin/listener /app/listener
CMD ["/app/listener"]
