using System.Net;
using System.Text;
using Azure.Messaging.ServiceBus;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Moq;

namespace AzureAlerting.Function.Tests;

public class SendMessageFunctionTests
{
    [Fact]
    public async Task RunAsync_ValidRequest_ReturnsAcceptedWithCorrelationId()
    {
        // Arrange
        var body = "{\"test\":true}";
        var request = CreateMockRequest(body);
        var mockSender = new Mock<ServiceBusSender>();
        var mockFactory = new Mock<IServiceBusSenderFactory>();
        mockFactory
            .Setup(f => f.CreateSender("messages"))
            .Returns(mockSender.Object);

        var logger = Mock.Of<ILogger<SendMessageFunction>>();
        var function = new SendMessageFunction(mockFactory.Object, logger);

        // Act
        var response = await function.RunAsync(request, CancellationToken.None);

        // Assert
        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        Assert.Contains("X-Correlation-Id", response.Headers.Select(h => h.Key));
        mockSender.Verify(
            s => s.SendMessageAsync(
                It.IsAny<ServiceBusMessage>(),
                It.IsAny<CancellationToken>()),
            Times.Once);
    }

    [Fact]
    public async Task RunAsync_SendFails_ReturnsInternalServerError()
    {
        // Arrange
        var body = "{\"test\":true}";
        var request = CreateMockRequest(body);
        var mockSender = new Mock<ServiceBusSender>();
        mockSender
            .Setup(s => s.SendMessageAsync(
                It.IsAny<ServiceBusMessage>(),
                It.IsAny<CancellationToken>()))
            .ThrowsAsync(new ServiceBusException(
                "Test failure", ServiceBusFailureReason.ServiceCommunicationProblem));

        var mockFactory = new Mock<IServiceBusSenderFactory>();
        mockFactory
            .Setup(f => f.CreateSender("messages"))
            .Returns(mockSender.Object);

        var logger = Mock.Of<ILogger<SendMessageFunction>>();
        var function = new SendMessageFunction(mockFactory.Object, logger);

        // Act
        var response = await function.RunAsync(request, CancellationToken.None);

        // Assert
        Assert.Equal(HttpStatusCode.InternalServerError, response.StatusCode);
    }

    [Fact]
    public async Task RunAsync_SimulateFailure_ReturnsInternalServerError()
    {
        // Arrange
        var body = "{\"test\":true}";
        var url = new Uri("https://localhost/api/send?simulateFailure=true");
        var request = CreateMockRequest(body, url);
        var mockSender = new Mock<ServiceBusSender>();
        var mockFactory = new Mock<IServiceBusSenderFactory>();
        mockFactory
            .Setup(f => f.CreateSender("messages"))
            .Returns(mockSender.Object);

        var logger = Mock.Of<ILogger<SendMessageFunction>>();
        var function = new SendMessageFunction(mockFactory.Object, logger);

        // Act
        var response = await function.RunAsync(request, CancellationToken.None);

        // Assert
        Assert.Equal(HttpStatusCode.InternalServerError, response.StatusCode);
        mockSender.Verify(
            s => s.SendMessageAsync(
                It.IsAny<ServiceBusMessage>(),
                It.IsAny<CancellationToken>()),
            Times.Never);
    }

    [Fact]
    public async Task RunAsync_SimulateDelay_ReturnsAccepted()
    {
        // Arrange
        var body = "{\"test\":true}";
        var url = new Uri("https://localhost/api/send?simulateDelay=100");
        var request = CreateMockRequest(body, url);
        var mockSender = new Mock<ServiceBusSender>();
        var mockFactory = new Mock<IServiceBusSenderFactory>();
        mockFactory
            .Setup(f => f.CreateSender("messages"))
            .Returns(mockSender.Object);

        var logger = Mock.Of<ILogger<SendMessageFunction>>();
        var function = new SendMessageFunction(mockFactory.Object, logger);

        // Act
        var response = await function.RunAsync(request, CancellationToken.None);

        // Assert
        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        mockSender.Verify(
            s => s.SendMessageAsync(
                It.IsAny<ServiceBusMessage>(),
                It.IsAny<CancellationToken>()),
            Times.Once);
    }

    [Fact]
    public async Task RunAsync_SimulateTimeout_ReturnsGatewayTimeout()
    {
        // Arrange
        var body = "{\"test\":true}";
        var url = new Uri("https://localhost/api/send?simulateTimeout=1");
        var request = CreateMockRequest(body, url);
        var mockSender = new Mock<ServiceBusSender>();
        var mockFactory = new Mock<IServiceBusSenderFactory>();
        mockFactory
            .Setup(f => f.CreateSender("messages"))
            .Returns(mockSender.Object);

        var logger = Mock.Of<ILogger<SendMessageFunction>>();
        var function = new SendMessageFunction(mockFactory.Object, logger);

        // Act
        var response = await function.RunAsync(request, CancellationToken.None);

        // Assert
        Assert.Equal(HttpStatusCode.GatewayTimeout, response.StatusCode);
        mockSender.Verify(
            s => s.SendMessageAsync(
                It.IsAny<ServiceBusMessage>(),
                It.IsAny<CancellationToken>()),
            Times.Never);
    }

    [Fact]
    public async Task RunAsync_SimulateFailureWithDelay_ReturnsInternalServerError()
    {
        // Arrange
        var body = "{\"test\":true}";
        var url = new Uri("https://localhost/api/send?simulateFailure=true&simulateDelay=50");
        var request = CreateMockRequest(body, url);
        var mockSender = new Mock<ServiceBusSender>();
        var mockFactory = new Mock<IServiceBusSenderFactory>();
        mockFactory
            .Setup(f => f.CreateSender("messages"))
            .Returns(mockSender.Object);

        var logger = Mock.Of<ILogger<SendMessageFunction>>();
        var function = new SendMessageFunction(mockFactory.Object, logger);

        // Act
        var response = await function.RunAsync(request, CancellationToken.None);

        // Assert
        Assert.Equal(HttpStatusCode.InternalServerError, response.StatusCode);
        mockSender.Verify(
            s => s.SendMessageAsync(
                It.IsAny<ServiceBusMessage>(),
                It.IsAny<CancellationToken>()),
            Times.Never);
    }

    [Fact]
    public async Task RunAsync_NoSimulationParams_SucceedsNormally()
    {
        // Arrange
        var body = "{\"test\":true}";
        var url = new Uri("https://localhost/api/send");
        var request = CreateMockRequest(body, url);
        var mockSender = new Mock<ServiceBusSender>();
        var mockFactory = new Mock<IServiceBusSenderFactory>();
        mockFactory
            .Setup(f => f.CreateSender("messages"))
            .Returns(mockSender.Object);

        var logger = Mock.Of<ILogger<SendMessageFunction>>();
        var function = new SendMessageFunction(mockFactory.Object, logger);

        // Act
        var response = await function.RunAsync(request, CancellationToken.None);

        // Assert
        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        mockSender.Verify(
            s => s.SendMessageAsync(
                It.IsAny<ServiceBusMessage>(),
                It.IsAny<CancellationToken>()),
            Times.Once);
    }

    private static HttpRequestData CreateMockRequest(string body, Uri? url = null)
    {
        var stream = new MemoryStream(Encoding.UTF8.GetBytes(body));
        var functionContext = new Mock<FunctionContext>();
        var request = new Mock<HttpRequestData>(MockBehavior.Strict, functionContext.Object);
        request.Setup(r => r.Body).Returns(stream);
        request.Setup(r => r.Url).Returns(url ?? new Uri("https://localhost/api/send"));
        request
            .Setup(r => r.CreateResponse())
            .Returns(() =>
            {
                var responseBody = new MemoryStream();
                var response = new Mock<HttpResponseData>(MockBehavior.Strict, functionContext.Object);
                response.SetupProperty(r => r.StatusCode);
                response.Setup(r => r.Headers).Returns(new HttpHeadersCollection());
                response.Setup(r => r.Body).Returns(responseBody);
                return response.Object;
            });
        return request.Object;
    }
}
