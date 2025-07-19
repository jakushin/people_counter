import React, { useRef, useEffect, useState } from 'react';
import DebugPanel from './DebugPanel';

export default function WebRTCStream() {
  const videoRef = useRef(null);
  const [status, setStatus] = useState('stopped'); // Изменено с 'connecting' на 'stopped'
  const [error, setError] = useState(null);
  const [connectionState, setConnectionState] = useState('new');
  const [iceConnectionState, setIceConnectionState] = useState('new');
  const [iceGatheringState, setIceGatheringState] = useState('new');
  const [isConnecting, setIsConnecting] = useState(false); // Новое состояние для контроля соединения
  const [serverStatus, setServerStatus] = useState(null); // Статус с сервера
  const [autoReconnectCountdown, setAutoReconnectCountdown] = useState(null); // Обратный отсчет автопереподключения

  const wsRef = useRef(null);
  const pcRef = useRef(null);
  const pendingIceCandidates = useRef([]); // Очередь для ICE candidates
  const autoReconnectTimeoutRef = useRef(null); // Таймер автопереподключения



  // Функция автопереподключения с обратным отсчетом
  const startAutoReconnectCountdown = () => {
    if (autoReconnectTimeoutRef.current) {
      clearTimeout(autoReconnectTimeoutRef.current);
    }
    
    let secondsLeft = 5;
    setAutoReconnectCountdown(secondsLeft);
    
    const countdown = () => {
      secondsLeft--;
      setAutoReconnectCountdown(secondsLeft);
      
      if (secondsLeft <= 0) {
        setAutoReconnectCountdown(null);
        console.log('WebRTC Debug: Auto-reconnecting after countdown');
        // Use existing WebSocket for auto-reconnection instead of creating new one
        startWebRTCWithExistingSocket();
      } else {
        autoReconnectTimeoutRef.current = setTimeout(countdown, 1000);
      }
    };
    
    autoReconnectTimeoutRef.current = setTimeout(countdown, 1000);
  };

  // Функция отмены автопереподключения
  const cancelAutoReconnect = () => {
    if (autoReconnectTimeoutRef.current) {
      clearTimeout(autoReconnectTimeoutRef.current);
      autoReconnectTimeoutRef.current = null;
    }
    setAutoReconnectCountdown(null);
    console.log('WebRTC Debug: Auto-reconnect cancelled by user');
  };

  // Функция auto-reconnection с существующим WebSocket 
  const startWebRTCWithExistingSocket = async () => {
    if (isConnecting) return;
    
    // Check if we have an active WebSocket connection
    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) {
      console.log('WebRTC Debug: No active WebSocket for auto-reconnection, creating new connection');
      startWebRTC();
      return;
    }
    
    console.log('WebRTC Debug: Starting WebRTC auto-reconnection with existing WebSocket connection');
    setIsConnecting(true);
    setStatus('connecting');
    setError(null);

    try {
      // Use existing WebSocket connection (don't create new one!)
      const websocket = wsRef.current;

      // Clean up old PeerConnection before creating new one
      if (pcRef.current) {
        console.log('WebRTC Debug: Closing old PeerConnection for auto-reconnection');
        pcRef.current.close();
        pcRef.current = null;
      }

      // Create new PeerConnection for the reconnection
      const config = {
        iceServers: [], // В host режиме STUN серверы не нужны
        iceCandidatePoolSize: 0, // Не генерируем кандидаты заранее
        iceTransportPolicy: 'all' // Разрешаем все типы кандидатов
      };
      
      const peerConnection = new RTCPeerConnection(config);
      pcRef.current = peerConnection;

      // Set up the same WebRTC handlers as in startWebRTC
      peerConnection.onconnectionstatechange = () => {
        const state = peerConnection.connectionState;
        setConnectionState(state);
        console.log('WebRTC connection state:', state);
        
        if (state === 'connected') {
          setStatus('connected');
          setError(null);
          setServerStatus(null);
          console.log('WebRTC connected successfully!');
        } else if (state === 'failed' || state === 'disconnected') {
          setStatus('failed');
          setError('WebRTC connection failed');
          setIsConnecting(false);
          console.error('WebRTC connection failed or disconnected');
        } else if (state === 'closed') {
          setStatus('stopped');
          setIsConnecting(false);
          console.log('WebRTC connection closed');
        }
      };
      
      peerConnection.oniceconnectionstatechange = () => {
        const iceState = peerConnection.iceConnectionState;
        setIceConnectionState(iceState);
        console.log(`WebRTC Debug: ICE connection state: ${iceState}`);
        
        if (iceState === 'failed') {
          setError('Network connection failed (ICE)');
          console.log('WebRTC Debug: ICE connection failed - network issues');
        } else if (iceState === 'connected') {
          console.log('WebRTC Debug: ICE connection established successfully');
        }
      };
      
      peerConnection.onicegatheringstatechange = () => {
        const gatheringState = peerConnection.iceGatheringState;
        setIceGatheringState(gatheringState);
        console.log(`WebRTC Debug: ICE gathering state: ${gatheringState}`);
      };

      peerConnection.ontrack = (event) => {
        console.log('Received remote track:', event.track.kind);
        if (videoRef.current) {
          if (videoRef.current.srcObject) {
            videoRef.current.srcObject.addTrack(event.track);
          } else {
            videoRef.current.srcObject = event.streams[0];
          }
        }
      };

      peerConnection.onicecandidate = (event) => {
        if (event.candidate && websocket.readyState === WebSocket.OPEN) {
          const candidateStr = event.candidate.candidate;
          if (candidateStr.includes('.local')) {
            console.log('WebRTC Debug: Skipping mDNS candidate (not suitable for cross-device connection)');
            return;
          }
          
          console.log(`WebRTC Debug: Sending ICE candidate: ${candidateStr.split(' ')[4]}:${candidateStr.split(' ')[5]}`);
          websocket.send(JSON.stringify({
            type: 'ice-candidate',
            candidate: event.candidate
          }));
        }
      };

      // Start WebRTC handshake immediately (WebSocket already connected)
      console.log('WebRTC Debug: Creating SDP offer for auto-reconnection');
      const offer = await peerConnection.createOffer({
        offerToReceiveVideo: true,
        offerToReceiveAudio: true
      });
      
      await peerConnection.setLocalDescription(offer);
      console.log('WebRTC Debug: Created and set local SDP offer');
      
      websocket.send(JSON.stringify({
        type: 'offer',
        sdp: offer.sdp
      }));
      console.log('WebRTC Debug: Sent SDP offer to server');
      
    } catch (err) {
      console.error('Auto-reconnection failed:', err);
      console.log(`WebRTC Debug: Auto-reconnection failed: ${err.message}`);
      setError('Auto-reconnection failed: ' + err.message);
      setStatus('failed');
      setIsConnecting(false);
    }
  };

  // Функция запуска WebRTC соединения
  const startWebRTC = async () => {
    if (isConnecting) return;
    
    setIsConnecting(true);
    setStatus('connecting');
    setError(null);

    try {
      // Создаем WebSocket соединение
      const wsUrl = `ws://${window.location.host}/api/webrtc/signal`;
      const websocket = new WebSocket(wsUrl);
      wsRef.current = websocket;

      // Простая конфигурация для host network режима
      const config = {
        iceServers: [], // В host режиме STUN серверы не нужны
        iceCandidatePoolSize: 0, // Не генерируем кандидаты заранее
        iceTransportPolicy: 'all' // Разрешаем все типы кандидатов (кроме отфильтрованных)
      };
      
      const peerConnection = new RTCPeerConnection(config);
      pcRef.current = peerConnection;

      // Обработка изменения состояния подключения
      peerConnection.onconnectionstatechange = () => {
        const state = peerConnection.connectionState;
        setConnectionState(state);
        console.log('WebRTC connection state:', state);
        
        if (state === 'connected') {
          setStatus('connected');
          setError(null);
          setServerStatus(null); // Очищаем статус сервера при успешном подключении
          console.log('WebRTC connected successfully!');
        } else if (state === 'failed' || state === 'disconnected') {
          setStatus('failed');
          setError('WebRTC connection failed');
          setIsConnecting(false);
          console.error('WebRTC connection failed or disconnected');
        } else if (state === 'closed') {
          setStatus('stopped');
          setIsConnecting(false);
          console.log('WebRTC connection closed');
        }
      };
      
      // Дополнительное логирование ICE состояния
      peerConnection.oniceconnectionstatechange = () => {
        const iceState = peerConnection.iceConnectionState;
        setIceConnectionState(iceState);
        console.log(`WebRTC Debug: ICE connection state: ${iceState}`);
        
        if (iceState === 'failed') {
          setError('Network connection failed (ICE)');
          console.log('WebRTC Debug: ICE connection failed - network issues');
        } else if (iceState === 'connected') {
          console.log('WebRTC Debug: ICE connection established successfully');
        }
      };
      
      // Логирование ICE gathering
      peerConnection.onicegatheringstatechange = () => {
        const gatheringState = peerConnection.iceGatheringState;
        setIceGatheringState(gatheringState);
        console.log(`WebRTC Debug: ICE gathering state: ${gatheringState}`);
      };

      // Обработка входящих медиа потоков
      peerConnection.ontrack = (event) => {
        console.log('Received remote track:', event.track.kind);
        if (videoRef.current) {
          if (videoRef.current.srcObject) {
            // Добавляем трек к существующему потоку
            videoRef.current.srcObject.addTrack(event.track);
          } else {
            // Создаем новый MediaStream
            videoRef.current.srcObject = event.streams[0];
          }
        }
      };

      // Обработка ICE candidates
      peerConnection.onicecandidate = (event) => {
        if (event.candidate && websocket.readyState === WebSocket.OPEN) {
          // Фильтруем mDNS candidates (.local адреса) которые не работают между устройствами
          const candidateStr = event.candidate.candidate;
          if (candidateStr.includes('.local')) {
            console.log('WebRTC Debug: Skipping mDNS candidate (not suitable for cross-device connection)');
            return;
          }
          
          console.log(`WebRTC Debug: Sending ICE candidate: ${candidateStr.split(' ')[4]}:${candidateStr.split(' ')[5]}`);
          websocket.send(JSON.stringify({
            type: 'ice-candidate',
            candidate: event.candidate
          }));
        }
      };

      // WebSocket обработчики
      websocket.onopen = async () => {
        console.log('WebRTC Debug: WebSocket connected to server');
        
        // Создаем SDP offer
        try {
          const offer = await peerConnection.createOffer({
            offerToReceiveVideo: true,
            offerToReceiveAudio: true
          });
          
          await peerConnection.setLocalDescription(offer);
          console.log('WebRTC Debug: Created and set local SDP offer');
          
          websocket.send(JSON.stringify({
            type: 'offer',
            sdp: offer.sdp
          }));
          console.log('WebRTC Debug: Sent SDP offer to server');
        } catch (err) {
          console.log(`WebRTC Debug: Failed to create offer: ${err.message}`);
          setError('Failed to create offer: ' + err.message);
          setStatus('failed');
          setIsConnecting(false);
        }
      };

      websocket.onmessage = async (event) => {
        try {
          const message = JSON.parse(event.data);
          console.log(`WebRTC Debug: Received: ${message.type}`);
          
          if (message.type === 'answer') {
            console.log('WebRTC Debug: Processing SDP answer from server');
            if (!pcRef.current) {
              console.log('WebRTC Debug: Error: peerConnection is not available');
              return;
            }
            const answer = new RTCSessionDescription({
              type: 'answer',
              sdp: message.sdp
            });
            await pcRef.current.setRemoteDescription(answer);
            console.log('WebRTC Debug: Set remote description successfully');
            
            // Обработка отложенных ICE candidates
            if (pendingIceCandidates.current.length > 0) {
              console.log(`WebRTC Debug: Processing ${pendingIceCandidates.current.length} pending ICE candidates`);
              for (const candidate of pendingIceCandidates.current) {
                try {
                  await pcRef.current.addIceCandidate(candidate);
                  console.log('WebRTC Debug: Added pending ICE candidate successfully');
                } catch (err) {
                  console.log(`WebRTC Debug: Failed to add pending ICE candidate: ${err.message}`);
                }
              }
              pendingIceCandidates.current = []; // Очищаем очередь
            }
                      } else if (message.type === 'ice-candidate') {
            console.log('WebRTC Debug: Processing ICE candidate from server');
            if (!pcRef.current) {
              console.log('WebRTC Debug: Error: peerConnection is not available for ICE candidate');
              return;
            }
            if (typeof pcRef.current.addIceCandidate !== 'function') {
              console.log('WebRTC Debug: Error: addIceCandidate is not a function');
              return;
            }
            
            const candidate = new RTCIceCandidate(message.candidate);
            
            // Если remote description еще не установлен, сохраняем candidate в очереди
            if (pcRef.current.remoteDescription === null) {
              console.log('WebRTC Debug: Remote description not set yet - adding ICE candidate to pending queue');
              pendingIceCandidates.current.push(candidate);
              return;
            }
            
            // Если remote description установлен, обрабатываем candidate сразу
            try {
              await pcRef.current.addIceCandidate(candidate);
              console.log('WebRTC Debug: Added ICE candidate successfully');
            } catch (err) {
              console.log(`WebRTC Debug: Failed to add ICE candidate: ${err.message}`);
              // Не останавливаем соединение из-за проблем с отдельным candidate
            }
          } else if (message.type === 'status') {
            console.log(`WebRTC Debug: Server status: ${message.message}`);
            setServerStatus(message.message); // Сохраняем статус для отображения
            setError(null); // Очищаем предыдущие ошибки
          } else if (message.type === 'error') {
            console.log(`WebRTC Debug: Server error: ${message.message}`);
            setError('Server error: ' + message.message);
            setStatus('failed');
            setIsConnecting(false);
          } else if (message.type === 'airplay_disconnected') {
            console.log(`WebRTC Debug: iPhone disconnected: ${message.message}`);
            setServerStatus('iPhone disconnected - waiting for reconnection...');
            setStatus('disconnected');
            // Don't set isConnecting to false - we want to keep the WebSocket open for auto-reconnect
          } else if (message.type === 'airplay_reconnecting') {
            console.log(`WebRTC Debug: iPhone reconnecting: ${message.message}`);
            setServerStatus('iPhone reconnected - starting WebRTC...');
            setStatus('connecting');
            setError(null);
          } else if (message.type === 'webrtc_ready') {
            console.log(`WebRTC Debug: WebRTC auto-reconnected: ${message.message}`);
            setServerStatus('WebRTC connected successfully');
            setStatus('connected');
            setError(null);
          } else if (message.type === 'reconnection_ready') {
            console.log(`WebRTC Debug: System ready for reconnection: ${message.message}`);
            
            // Check if WebRTC is already connected and working
            if (pcRef.current && pcRef.current.connectionState === 'connected') {
              console.log('WebRTC Debug: WebRTC already connected - ignoring reconnection_ready');
              setServerStatus('WebRTC already connected - no reconnection needed');
              return;
            }
            
            setServerStatus('iPhone reconnected - auto-reconnecting in 5 seconds');
            setStatus('ready_for_reconnect');
            setError(null);
            startAutoReconnectCountdown();
          } else if (message.type === 'window_changed') {
            console.log(`WebRTC Debug: iPhone window changed: ${message.message}`);
            
            // Check if WebRTC is already connected and working
            if (pcRef.current && pcRef.current.connectionState === 'connected') {
              console.log('WebRTC Debug: WebRTC already connected - ignoring window_changed');
              setServerStatus('WebRTC already connected - no window change reconnection needed');
              return;
            }
            
            setServerStatus('iPhone reconnected with new window - auto-reconnecting in 5 seconds');
            setStatus('ready_for_reconnect');
            setError(null);
            startAutoReconnectCountdown();
          }
        } catch (err) {
          console.log(`WebRTC Debug: Signaling error: ${err.message}`);
          setError('Signaling error: ' + err.message);
        }
      };

      websocket.onerror = (err) => {
        console.error('WebSocket error:', err);
        setError('WebSocket connection failed');
        setStatus('failed');
        setIsConnecting(false);
      };

      websocket.onclose = () => {
        console.log('WebSocket closed');
        console.log('WebRTC Debug: WebSocket connection closed by server');
        
        if (status !== 'stopped') {
          setStatus('disconnected');
          setIsConnecting(false);
          
          // Автоматическое переподключение через 2 секунды
          console.log('WebRTC Debug: Attempting to reconnect WebSocket in 2 seconds...');
          setTimeout(() => {
            if (status !== 'stopped') {
              console.log('WebRTC Debug: Auto-reconnecting WebSocket...');
              startWebRTC();
            }
          }, 2000);
        }
      };

    } catch (err) {
      console.error('Failed to start WebRTC:', err);
      setError('Failed to start WebRTC: ' + err.message);
      setStatus('failed');
      setIsConnecting(false);
    }
  };

  // Функция остановки WebRTC соединения
  const stopWebRTC = () => {
    console.log('WebRTC Debug: Stopping WebRTC connection');
    
    // Отменяем автопереподключение если активно
    cancelAutoReconnect();
    
    setIsConnecting(false);
    setStatus('stopped');
    setError(null);
    setServerStatus(null); // Очищаем статус сервера
    setConnectionState('new');
    setIceConnectionState('new');
    setIceGatheringState('new');
    
    // Очищаем очередь ICE candidates
    pendingIceCandidates.current = [];
    
    // Останавливаем видео
    if (videoRef.current && videoRef.current.srcObject) {
      const tracks = videoRef.current.srcObject.getTracks();
      tracks.forEach(track => track.stop());
      videoRef.current.srcObject = null;
    }
    
    // Закрываем WebSocket
    if (wsRef.current) {
      wsRef.current.close();
      wsRef.current = null;
    }
    
    // Закрываем peer connection
    if (pcRef.current) {
      pcRef.current.close();
      pcRef.current = null;
    }
    
    console.log('WebRTC Debug: WebRTC connection stopped');
  };

  // Очистка при размонтировании
  useEffect(() => {
    return () => {
      stopWebRTC();
      cancelAutoReconnect();
    };
  }, []);

  return (
    <div>
      {/* Кнопки управления WebRTC */}
      <div style={{margin:'16px 0', display:'flex', gap:'12px', alignItems:'center'}}>
        <button 
          onClick={startWebRTC}
          disabled={isConnecting || autoReconnectCountdown !== null}
          style={{
            padding:'8px 16px',
            backgroundColor: isConnecting || autoReconnectCountdown !== null ? '#6c757d' : 
                           status === 'ready_for_reconnect' ? '#ffc107' : '#28a745',
            color: 'white',
            border: 'none',
            borderRadius:'4px',
            cursor: isConnecting || autoReconnectCountdown !== null ? 'not-allowed' : 'pointer'
          }}
        >
          {isConnecting ? 'Подключается...' : 
           autoReconnectCountdown !== null ? `Auto-reconnect (${autoReconnectCountdown}s)` :
           status === 'ready_for_reconnect' ? 'Start WebRTC (Ready!)' : 'Start WebRTC'}
        </button>
        
        {autoReconnectCountdown !== null && (
          <button 
            onClick={cancelAutoReconnect}
            style={{
              padding:'8px 16px',
              backgroundColor: '#dc3545',
              color: 'white',
              border: 'none',
              borderRadius:'4px',
              cursor: 'pointer'
            }}
          >
            Cancel Auto-reconnect
          </button>
        )}
        
        <button 
          onClick={stopWebRTC}
          disabled={!isConnecting && status === 'stopped'}
          style={{
            padding:'8px 16px',
            backgroundColor: (!isConnecting && status === 'stopped') ? '#6c757d' : '#dc3545',
            color: 'white',
            border: 'none',
            borderRadius:'4px',
            cursor: (!isConnecting && status === 'stopped') ? 'not-allowed' : 'pointer'
          }}
        >
          Stop
        </button>
        <button 
          onClick={() => setDebugInfo([])}
          style={{
            padding:'8px 16px',
            backgroundColor: '#6c757d',
            color: 'white',
            border: 'none',
            borderRadius:'4px',
            cursor: 'pointer'
          }}
        >
          Clear Debug
        </button>
      </div>

      <div style={{margin:'24px 0'}}>
        <div style={{border:'1px solid #ccc', width:640, height:360, background:'#222', display:'flex', alignItems:'center', justifyContent:'center'}}>
          <video 
            ref={videoRef} 
            width={640} 
            height={360} 
            autoPlay 
            controls 
            playsInline 
            style={{background:'#222'}}
            poster="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='360'%3E%3Crect width='100%25' height='100%25' fill='%23222'/%3E%3Ctext x='50%25' y='50%25' text-anchor='middle' dy='0.35em' fill='%23888' font-family='Arial' font-size='24'%3EНажмите Start для подключения%3C/text%3E%3C/svg%3E"
          />
        </div>
      </div>
      
      <div style={{margin:'24px 0'}}>
        <div style={{marginBottom: '8px'}}>
          <strong>WebRTC Status:</strong> <span style={{color: status === 'connected' ? 'green' : status === 'failed' ? 'red' : 'orange'}}>{status}</span>
        </div>
        
        {serverStatus && (
          <div style={{marginBottom: '8px', padding: '8px', backgroundColor: '#f8f9fa', border: '1px solid #dee2e6', borderRadius: '4px'}}>
            <strong>Server Status:</strong> <span style={{color: '#007bff'}}>{serverStatus}</span>
          </div>
        )}
        
        <div style={{display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: '16px', fontSize: '14px', color: '#666'}}>
          <div>
            <strong>Connection:</strong> {connectionState}
          </div>
          <div>
            <strong>ICE Connection:</strong> {iceConnectionState}
          </div>
          <div>
            <strong>ICE Gathering:</strong> {iceGatheringState}
          </div>
        </div>
      </div>
      
      {error && <div style={{color:'red', marginBottom: '16px', padding: '8px', backgroundColor: '#ffe6e6', border: '1px solid #ffcccc', borderRadius: '4px'}}>{error}</div>}
      
      {/* Debug Panel */}
      <DebugPanel />
    </div>
  );
} 