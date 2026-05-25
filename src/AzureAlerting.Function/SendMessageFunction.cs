using System.Text;
using System.Text.Json;
using Azure.Messaging.ServiceBus;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace AzureAlerting.Function;

public class SendMessageFunction
{
    private readonly IServiceBusSenderFactory _senderFactory;
    private readonly ILogger<SendMessageFunction> _logger;

    // TODO: Replace with queue name from configuration in production
    private const string QueueName = "messages";

    public SendMessageFunction(
        IServiceBusSenderFactory senderFactory,
        ILogger<SendMessageFunction> logger)
    {
        _senderFactory = senderFactory;
        _logger = logger;
    }

    [Function("SendMessage")]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "send")]
        HttpRequestData request,
        CancellationToken cancellationToken)
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

        // --- Simulation modes (for alert testing) ---
        var query = request.Url.Query;
        var simulateFailure = query.Contains(
            "simulateFailure=true", StringComparison.OrdinalIgnoreCase);
        // simulateTimeout can be "true" (default 230s) or a number in seconds
        int timeoutSecs = 0;
        if (query.Contains(
            "simulateTimeout=true", StringComparison.OrdinalIgnoreCase))
        {
            timeoutSecs = 230;
        }
        else
        {
            var timeoutMatch = System.Text.RegularExpressions.Regex.Match(
                query, @"simulateTimeout=(\d+)");
            if (timeoutMatch.Success)
            {
                _ = int.TryParse(timeoutMatch.Groups[1].Value, out timeoutSecs);
            }
        }

        int delayMs = 0;
        var delayMatch = System.Text.RegularExpressions.Regex.Match(
            query, @"simulateDelay=(\d+)");
        if (delayMatch.Success)
        {
            _ = int.TryParse(delayMatch.Groups[1].Value, out delayMs);
        }

        try
        {
            // Simulate artificial delay (function_p95_response_time alert)
            if (delayMs > 0)
            {
                _logger.LogWarning(
                    "Simulating {DelayMs}ms delay. CorrelationId: {CorrelationId}",
                    delayMs, correlationId);
                await Task.Delay(delayMs, cancellationToken);
            }

            // Simulate Service Bus failure (function_failure_rate,
            // dependency_failure_rate, send_failure_spike alerts)
            if (simulateFailure)
            {
                _logger.LogWarning(
                    "Simulating Service Bus failure. CorrelationId: {CorrelationId}",
                    correlationId);
                throw new ServiceBusException(
                    "Simulated service communication problem",
                    ServiceBusFailureReason.ServiceCommunicationProblem);
            }

            // Simulate timeout (function_timeout_rate alert)
            if (timeoutSecs > 0)
            {
                _logger.LogWarning(
                    "Simulating {TimeoutSecs}s timeout. CorrelationId: {CorrelationId}",
                    timeoutSecs, correlationId);
                await Task.Delay(timeoutSecs * 1000, cancellationToken);

                var timeoutResponse = request.CreateResponse(
                    System.Net.HttpStatusCode.GatewayTimeout);
                timeoutResponse.Headers.Add("X-Correlation-Id", correlationId);
                await timeoutResponse.WriteStringAsync(
                    JsonSerializer.Serialize(new
                    {
                        correlationId,
                        status = "timeout",
                        message = "Simulated timeout (230s)"
                    }));
                return timeoutResponse;
            }

            await using var sender = _senderFactory.CreateSender(QueueName);

            var message = new ServiceBusMessage(requestBody)
            {
                MessageId = correlationId,
                ContentType = "application/json"
            };
            message.ApplicationProperties.Add("Source", "az-alerting");
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
