using System;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Threading.Tasks;
using Impostor.Api.Config;
using Impostor.Api.Events.Managers;
using Impostor.Api.Net.Messages.C2S;
using Impostor.Hazel;
using Impostor.Hazel.Dtls;
using Impostor.Hazel.Udp;
using Impostor.Server.Events.Client;
using Impostor.Server.Net.Hazel;
using Impostor.Server.Net.Manager;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.ObjectPool;
using Microsoft.Extensions.Options;

namespace Impostor.Server.Net
{
    internal class Matchmaker
    {
        private readonly IEventManager _eventManager;
        private readonly ClientManager _clientManager;
        private readonly ObjectPool<MessageReader> _readerPool;
        private readonly ILogger<HazelConnection> _connectionLogger;
        private readonly IOptions<AntiCheatConfig> _antiCheatOptions;
        private UdpConnectionListener? _connection;
        private DtlsConnectionListener? _dtlsConnection;

        public Matchmaker(
            IEventManager eventManager,
            ClientManager clientManager,
            ObjectPool<MessageReader> readerPool,
            ILogger<HazelConnection> connectionLogger,
            IOptions<AntiCheatConfig> antiCheatOptions)
        {
            _eventManager = eventManager;
            _clientManager = clientManager;
            _readerPool = readerPool;
            _connectionLogger = connectionLogger;
            _antiCheatOptions = antiCheatOptions;
        }

        public async ValueTask StartAsync(IPEndPoint ipEndPoint, IPEndPoint? dtlsEndPoint = null)
        {
            var mode = ipEndPoint.AddressFamily switch
            {
                AddressFamily.InterNetwork => IPMode.IPv4,
                AddressFamily.InterNetworkV6 => IPMode.IPv6,
                _ => throw new InvalidOperationException(),
            };

            _connection = new UdpConnectionListener(ipEndPoint, _readerPool, mode)
            {
                NewConnection = OnNewConnection,
            };

            await _connection.StartAsync();

            if (dtlsEndPoint != null)
            {
                DtlsWireVersion.Value = 0;

                _dtlsConnection = new DtlsConnectionListener(dtlsEndPoint, _readerPool, mode)
                {
                    NewConnection = OnNewConnection,
                };

                _dtlsConnection.SetCertificate(CreateSelfSignedCertificate());

                await _dtlsConnection.StartAsync();
            }
        }

        public async ValueTask StopAsync()
        {
            if (_dtlsConnection != null)
            {
                await _dtlsConnection.DisposeAsync();
            }

            if (_connection != null)
            {
                await _connection.DisposeAsync();
            }
        }

        private static X509Certificate2 CreateSelfSignedCertificate()
        {
            using var rsa = RSA.Create(2048);
            var request = new CertificateRequest("CN=Impostor", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
            return new X509Certificate2(certificate.Export(X509ContentType.Pfx));
        }

        private async ValueTask OnNewConnection(NewConnectionEventArgs e)
        {
            // Handshake.
            HandshakeC2S.Deserialize(e.HandshakeData, out var clientVersion, out var name, out var language, out var chatMode, out var platformSpecificData);

            var connection = new HazelConnection(e.Connection, _connectionLogger, _antiCheatOptions);

            await _eventManager.CallAsync(new ClientConnectionEvent(connection, e.HandshakeData));

            // Register client
            await _clientManager.RegisterConnectionAsync(connection, name, clientVersion, language, chatMode, platformSpecificData);
        }
    }
}
