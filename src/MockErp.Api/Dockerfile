# Build context: repository root  (docker build -f src/MockErp.Api/Dockerfile .)
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY src/ServicePortal.Shared/ServicePortal.Shared.csproj src/ServicePortal.Shared/
COPY src/MockErp.Api/MockErp.Api.csproj src/MockErp.Api/
RUN dotnet restore src/MockErp.Api/MockErp.Api.csproj
COPY src/ServicePortal.Shared/ src/ServicePortal.Shared/
COPY src/MockErp.Api/ src/MockErp.Api/
RUN dotnet publish src/MockErp.Api/MockErp.Api.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /app .
USER app
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "MockErp.Api.dll"]
