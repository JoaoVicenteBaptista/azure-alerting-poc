using Azure.Messaging.ServiceBus;

namespace AzureAlerting.Function;

public class ServiceBusSenderFactory(ServiceBusClient client) : IServiceBusSenderFactory
{
    public ServiceBusSender CreateSender(string queueOrTopic)
        => client.CreateSender(queueOrTopic);
}
