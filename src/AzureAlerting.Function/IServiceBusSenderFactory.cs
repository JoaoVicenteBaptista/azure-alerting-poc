using Azure.Messaging.ServiceBus;

namespace AzureAlerting.Function;

public interface IServiceBusSenderFactory
{
    ServiceBusSender CreateSender(string queueOrTopic);
}
