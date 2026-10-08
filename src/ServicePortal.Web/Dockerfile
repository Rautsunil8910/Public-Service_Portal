# Build context: repository root  (docker build -f src/ServicePortal.Web/Dockerfile .)
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY src/ServicePortal.Shared/ServicePortal.Shared.csproj src/ServicePortal.Shared/
COPY src/ServicePortal.Web/ServicePortal.Web.csproj src/ServicePortal.Web/
RUN dotnet restore src/ServicePortal.Web/ServicePortal.Web.csproj
COPY src/ServicePortal.Shared/ src/ServicePortal.Shared/
COPY src/ServicePortal.Web/ src/ServicePortal.Web/
RUN dotnet publish src/ServicePortal.Web/ServicePortal.Web.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /app .
USER app
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "ServicePortal.Web.dll"]
