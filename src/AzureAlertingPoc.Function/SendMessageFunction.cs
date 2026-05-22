using System.Text;
using System.Text.Json;
using Azure.Messaging.ServiceBus;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace AzureAlertingPoc.Function;

public class SendMessageFunction
{
    private readonly ServiceBusClient _serviceBusClient;
    private readonly ILogger<SendMessageFunction> _logger;

    // TODO: Replace with queue name from configuration in production
    private const string QueueName = "messages";

    public SendMessageFunction(
        ServiceBusClient serviceBusClient,
        ILogger<SendMessageFunction> logger)
    {
        _serviceBusClient = serviceBusClient;
        _logger = logger;
    }

    [Function("SendMessage")]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "send")]
        HttpRequestData request)
    {
        var correlationId = Guid.NewGuid().ToString("D");

        string requestBody;
        using (var reader = new StreamReader(request.Body, Encoding.UTF8))
        {
            requestBody = await reader.ReadToEndAsync();
        }

        _logger.LogInformation(
            "Received send request. CorrelationId: {CorrelationId}, BodySize: {BodySize}",
            correlationId,
            requestBody.Length);

        try
        {
            var sender = _serviceBusClient.CreateSender(QueueName);

            var message = new ServiceBusMessage(requestBody)
            {
                MessageId = correlationId,
                ContentType = "application/json"
            };
            message.ApplicationProperties.Add("Source", "az-alerting-poc");
            message.ApplicationProperties.Add("CorrelationId", correlationId);

            await sender.SendMessageAsync(message);

            _logger.LogInformation(
                "Message sent to queue. CorrelationId: {CorrelationId}, MessageId: {MessageId}",
                correlationId,
                message.MessageId);

            var response = request.CreateResponse(System.Net.HttpStatusCode.Accepted);
            response.Headers.Add("X-Correlation-Id", correlationId);
            await response.WriteStringAsync(
                JsonSerializer.Serialize(new { correlationId, status = "accepted" }));

            return response;
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Failed to send message to queue. CorrelationId: {CorrelationId}",
                correlationId);

            var errorResponse = request.CreateResponse(
                System.Net.HttpStatusCode.InternalServerError);
            await errorResponse.WriteStringAsync(
                JsonSerializer.Serialize(new
                {
                    correlationId,
                    status = "error",
                    error = "Failed to send message to Service Bus queue"
                }));

            return errorResponse;
        }
    }
}
