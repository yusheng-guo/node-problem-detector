
# How to build multi-arch docker with docker buildx
## debug with log input, use the cmd below.
```
docker buildx build -t npd-test:v1  --platform linux/arm64 . -f ./builder/Dockerfile.dind --progress plain
```