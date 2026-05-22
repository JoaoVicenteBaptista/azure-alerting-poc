using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace AzureAlertingPoc.Function;

public class Program
{
    public static void Main(string[] args)
    {
        var host = new HostBuilder()
            .ConfigureFunctionsWebApplication()
            .ConfigureServices(services =>
            {
                services.AddSingleton(provider =>
                {
                    var fullyQualifiedNamespace = Environment
                        .GetEnvironmentVariable(
                            "ServiceBusConnection__fullyQualifiedNamespace")
                        ?? throw new InvalidOperationException(
                            "ServiceBusConnection__fullyQualifiedNamespace " +
                            "environment variable is not set.");

                    var credential = new Azure.Identity.DefaultAzureCredential();

                    return new ServiceBusClient(
                        fullyQualifiedNamespace,
                        credential);
                });
            })
            .Build();

        host.Run();
    }
}
