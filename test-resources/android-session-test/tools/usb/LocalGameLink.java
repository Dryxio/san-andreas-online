import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.Socket;
import java.net.SocketAddress;
import java.util.concurrent.atomic.AtomicReference;

/** Private device test link. One signed length followed by one unchanged UDP datagram. */
public final class LocalGameLink {
    private static final int MAX_DATAGRAM = 65507;

    public static void main(String[] args) throws IOException {
        InetAddress loopback = InetAddress.getByName("127.0.0.1");
        try (DatagramSocket game = new DatagramSocket(22003, loopback);
             Socket usb = new Socket(loopback, 42673)) {
            usb.setTcpNoDelay(true);
            AtomicReference<SocketAddress> peer = new AtomicReference<>();
            DataInputStream fromHost = new DataInputStream(usb.getInputStream());
            DataOutputStream toHost = new DataOutputStream(usb.getOutputStream());
            Thread receiver = new Thread(() -> {
                try {
                    byte[] buffer = new byte[MAX_DATAGRAM];
                    while (true) {
                        int length = fromHost.readInt();
                        if (length < 0 || length > buffer.length) throw new IOException("Invalid frame length");
                        fromHost.readFully(buffer, 0, length);
                        SocketAddress destination = peer.get();
                        if (destination != null) game.send(new DatagramPacket(buffer, length, destination));
                    }
                } catch (IOException closed) {
                    game.close();
                }
            });
            receiver.setDaemon(true);
            receiver.start();

            byte[] buffer = new byte[MAX_DATAGRAM];
            while (!game.isClosed()) {
                DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                game.receive(packet);
                SocketAddress sender = packet.getSocketAddress();
                if (!sender.equals(peer.getAndSet(sender))) toHost.writeInt(-1);
                toHost.writeInt(packet.getLength());
                toHost.write(buffer, 0, packet.getLength());
                toHost.flush();
            }
        }
    }
}
