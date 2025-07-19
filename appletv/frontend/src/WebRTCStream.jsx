import React, { useRef, useEffect, useState } from 'react';
import DebugPanel from './DebugPanel';

export default function WebRTCStream() {
  const videoRef = useRef(null);
  const [status, setStatus] = useState('stopped'); // Изменено с 'connecting' на 'stopped'
  
  // Обертка для setStatus с логированием
  const setStatusWithLog = (newStatus) => {
    console.log(`📊 STATUS CHANGE: ${status} → ${newStatus}`);
    
    // Also log status changes to debug console
    if (window.debugLogUserAction && status !== newStatus) {
      window.debugLogUserAction('WebRTC Status Change', `${status} → ${newStatus}`);
    }
    
    setStatus(newStatus);
  };
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

  // Critical diagnostic: Monitor isConnecting state changes
  useEffect(() => {
    console.log(`📊 STATE CHANGE - isConnecting changed to: ${isConnecting}`);
    if (window.debugLogUserAction) {
      window.debugLogUserAction('State Change', `isConnecting changed to: ${isConnecting}`);
    }
  }, [isConnecting]);

  // Critical diagnostic: Monitor status state changes  
  useEffect(() => {
    console.log(`📊 STATE CHANGE - status changed to: ${status}`);
    if (window.debugLogUserAction) {
      window.debugLogUserAction('State Change', `status changed to: ${status}`);
    }
  }, [status]);

  // Функция автопереподключения с обратным отсчетом
  const startAutoReconnectCountdown = () => {
    console.log('🚨 [DIAG] startAutoReconnectCountdown() CALLED');
    if (window.debugLogUserAction) {
      window.debugLogUserAction('Auto-reconnect Countdown', 'startAutoReconnectCountdown() function called');
    }
    
    if (autoReconnectTimeoutRef.current) {
      console.log('🚨 [DIAG] Clearing existing countdown timer');
      clearTimeout(autoReconnectTimeoutRef.current);
    }
    
    setAutoReconnectCountdown(5);
    console.log('🚨 [DIAG] Countdown set to 5 seconds');

    const countdown = () => {
      console.log('🚨 [DIAG] countdown() function called');
      setAutoReconnectCountdown(prev => {
        console.log(`🚨 [DIAG] Countdown tick: ${prev} -> ${prev - 1}`);
        const newCount = prev - 1;
        
        if (newCount <= 0) {
          console.log('🚨 [DIAG] COUNTDOWN REACHED ZERO - Starting final check');
          
          // Final check before auto-reconnection
          const isWebRTCWorking = pcRef.current && 
            pcRef.current.connectionState === 'connected';
          const isVideoWorking = videoRef.current && 
            videoRef.current.srcObject && 
            videoRef.current.srcObject.getTracks().length > 0;
          
          console.log(`🚨 [DIAG] FINAL CHECK RESULTS:`);
          console.log(`  - isWebRTCWorking: ${isWebRTCWorking}`);
          console.log(`  - isVideoWorking: ${isVideoWorking}`);
          console.log(`  - pcRef.current: ${pcRef.current ? 'exists' : 'null'}`);
          console.log(`  - pcRef.connectionState: ${pcRef.current?.connectionState}`);
          console.log(`  - videoRef.current: ${videoRef.current ? 'exists' : 'null'}`);
          console.log(`  - videoRef.srcObject: ${videoRef.current?.srcObject ? 'exists' : 'null'}`);
          console.log(`  - video tracks count: ${videoRef.current?.srcObject?.getTracks().length || 0}`);
          
          if (window.debugLogUserAction) {
            window.debugLogUserAction('Auto-reconnect Final Check', 
              `WebRTC: ${isWebRTCWorking}, Video: ${isVideoWorking}, PC: ${pcRef.current?.connectionState}, Tracks: ${videoRef.current?.srcObject?.getTracks().length || 0}`);
          }
          
          if (isWebRTCWorking || isVideoWorking) {
            console.log('🚫 [DIAG] COUNTDOWN FINAL CHECK: WebRTC/Video working - CANCELLING auto-reconnection');
            setServerStatus('Auto-reconnection cancelled - WebRTC already working');
            
            // Log countdown cancellation
            if (window.debugLogUserAction) {
              window.debugLogUserAction('Auto-reconnect Cancelled', 'Final check detected working WebRTC - countdown cancelled');
            }
            
            return null; // Reset countdown
          }
          
          console.log('✅ [DIAG] COUNTDOWN FINAL CHECK: WebRTC not working - proceeding with auto-reconnection');
          console.log('🚀 [DIAG] CALLING startWebRTCWithExistingSocket()');
          
          // Log automatic reconnection
          if (window.debugLogUserAction) {
            window.debugLogUserAction('Auto-reconnect Triggered', 'System automatically reconnecting after 5 second countdown');
          }
          
          // Use existing WebSocket for auto-reconnection instead of creating new one
          startWebRTCWithExistingSocket();
          return null; // Reset countdown
        } else {
          console.log(`🚨 [DIAG] Scheduling next countdown tick for ${newCount}s`);
          autoReconnectTimeoutRef.current = setTimeout(countdown, 1000);
          return newCount;
        }
      });
    };
    
    console.log('🚨 [DIAG] Starting initial countdown timer');
    autoReconnectTimeoutRef.current = setTimeout(countdown, 1000);
  };

  // Функция отмены автопереподключения
  const cancelAutoReconnect = () => {
    console.log('🚫 [DIAG] cancelAutoReconnect() CALLED');
    console.log(`🚫 [DIAG] Current countdown: ${autoReconnectCountdown}`);
    console.log(`🚫 [DIAG] Timeout ref exists: ${!!autoReconnectTimeoutRef.current}`);
    
    // Log user action if called manually (not automatically)
    if (autoReconnectCountdown !== null && window.debugLogUserAction) {
      window.debugLogUserAction('Cancel Auto-reconnect', `Cancelled with ${autoReconnectCountdown} seconds remaining`);
    }
    
    if (autoReconnectTimeoutRef.current) {
      console.log('🚫 [DIAG] Clearing timeout');
      clearTimeout(autoReconnectTimeoutRef.current);
      autoReconnectTimeoutRef.current = null;
    }
    setAutoReconnectCountdown(null);
    console.log('🚫 [DIAG] Auto-reconnect cancelled by user');
  };

  // Функция auto-reconnection с существующим WebSocket 
  const startWebRTCWithExistingSocket = async () => {
    console.log('🚀 [DIAG] startWebRTCWithExistingSocket() CALLED');
    console.log(`🚀 [DIAG] Current state - isConnecting: ${isConnecting}, status: ${status}`);
    console.log(`🚀 [DIAG] WebSocket state: ${wsRef.current ? wsRef.current.readyState : 'null'}`);
    
    if (window.debugLogUserAction) {
      window.debugLogUserAction('Auto-reconnect With Existing Socket', 
        `Called with isConnecting: ${isConnecting}, WS state: ${wsRef.current?.readyState}`);
    }
    
    if (isConnecting) {
      console.log('🚫 [DIAG] BLOCKED: isConnecting is already true');
      return;
    }
    
    // Check if we have an active WebSocket connection
    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) {
      console.log('🚫 [DIAG] No active WebSocket for auto-reconnection, creating new connection');
      console.log('🔄 [DIAG] FALLBACK: Calling startWebRTC() instead');
      if (window.debugLogUserAction) {
        window.debugLogUserAction('Auto-reconnect Fallback', 'No active WebSocket, falling back to startWebRTC()');
      }
      startWebRTC();
      return;
    }
    
    console.log('✅ [DIAG] Starting WebRTC auto-reconnection with existing WebSocket connection');
    setIsConnecting(true);
    setStatusWithLog('connecting');
    setError(null);

    try {
      console.log('🔧 [DIAG] Creating new RTCPeerConnection...');
      // Use existing WebSocket connection (don't create new one!)
      
      // Close existing peer connection if any
      if (pcRef.current) {
        console.log('🔧 [DIAG] Closing existing PeerConnection');
        pcRef.current.close();
      }
      
      // Простая конфигурация для host network режима
      const config = {
        iceServers: [
          { urls: 'stun:stun.l.google.com:19302' }
        ]
      };
      
      const peerConnection = new RTCPeerConnection(config);
      pcRef.current = peerConnection;
      console.log('✅ [DIAG] New PeerConnection created');

      // Set up the same WebRTC handlers as in startWebRTC
      peerConnection.onconnectionstatechange = () => {
        const state = peerConnection.connectionState;
        setConnectionState(state);
        console.log(`🔄 [DIAG] WebRTC connection state: ${state}`);
        
        if (state === 'connected') {
          setStatusWithLog('connected');
          setError(null);
          setServerStatus(null);
          console.log('✅ [DIAG] WebRTC connected successfully!');
          if (window.debugLogUserAction) {
            window.debugLogUserAction('Auto-reconnect Success', 'WebRTC auto-reconnection successful');
          }
        }
        setIsConnecting(false);
      };

      peerConnection.oniceconnectionstatechange = () => {
        const state = peerConnection.iceConnectionState;
        setIceConnectionState(state);
        console.log(`🧊 [DIAG] ICE connection state: ${state}`);
      };

      peerConnection.onicegatheringstatechange = () => {
        const state = peerConnection.iceGatheringState;
        setIceGatheringState(state);
        console.log(`🧊 [DIAG] ICE gathering state: ${state}`);
      };

      // Handle incoming media tracks
      peerConnection.ontrack = (event) => {
        console.log('📺 [DIAG] Received media track:', event.track.kind);
        if (event.track.kind === 'video' && videoRef.current) {
          console.log('✅ [DIAG] Setting video srcObject');
          videoRef.current.srcObject = event.streams[0];
          if (window.debugLogUserAction) {
            window.debugLogUserAction('Auto-reconnect Video', 'Video track received and set');
          }
        }
      };

      // Handle ICE candidates
      peerConnection.onicecandidate = (event) => {
        if (event.candidate && wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
          console.log('🧊 [DIAG] Sending ICE candidate');
          wsRef.current.send(JSON.stringify({
            type: 'ice-candidate',
            candidate: event.candidate
          }));
        }
      };

      console.log('🔧 [DIAG] Creating SDP offer...');
      // Create and set local description
      const offer = await peerConnection.createOffer({
        offerToReceiveVideo: true,
        offerToReceiveAudio: true
      });
      
      await peerConnection.setLocalDescription(offer);
      console.log('✅ [DIAG] Local description set');

      // Send offer through existing WebSocket
      console.log('📤 [DIAG] Sending SDP offer through existing WebSocket');
      wsRef.current.send(JSON.stringify({
        type: 'offer',
        sdp: offer.sdp
      }));
      console.log('✅ [DIAG] SDP offer sent successfully');
      
      if (window.debugLogUserAction) {
        window.debugLogUserAction('Auto-reconnect SDP', 'SDP offer sent through existing WebSocket');
      }
      
    } catch (err) {
      console.error('💥 [DIAG] Auto-reconnection failed:', err);
      console.log(`💥 [DIAG] Auto-reconnection failed: ${err.message}`);
      if (window.debugLogUserAction) {
        window.debugLogUserAction('Auto-reconnect Error', `Failed: ${err.message}`);
      }
      setError('Auto-reconnection failed: ' + err.message);
      setStatusWithLog('failed');
      setIsConnecting(false);
    }
  };

  // Функция запуска WebRTC соединения
  const startWebRTC = async () => {
    console.log(`🚀 START WEBRTC CALLED - isConnecting: ${isConnecting}, status: ${status}`);
    
    if (isConnecting) {
      console.log(`🚫 START WEBRTC BLOCKED - isConnecting is already true`);
      
      // ИСПРАВЛЕНИЕ: Проверяем нет ли "застрявшего" состояния и принудительно сбрасываем если нет активных соединений
      const hasActiveConnections = (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) || 
                                   (pcRef.current && pcRef.current.connectionState === 'connected');
      
      if (!hasActiveConnections && status !== 'connecting') {
        console.log(`🔧 RECONNECT FIX: isConnecting=true but no active connections, forcing reset`);
        setIsConnecting(false);
        // Retry after small delay
        setTimeout(() => {
          console.log(`🔄 RECONNECT FIX: Retrying startWebRTC after forced reset`);
          startWebRTC();
        }, 100);
        return;
      }
      
      console.log(`🚫 START WEBRTC BLOCKED - returning early (has active connections)`);
      return;
    }
    
    // Log user action
    if (window.debugLogUserAction) {
      window.debugLogUserAction('Start WebRTC', `Current status: ${status}`);
    }
    
    console.log(`🚀 START WEBRTC PROCEEDING - setting isConnecting=true, status=connecting`);
    setIsConnecting(true);
    setStatusWithLog('connecting');
    setError(null);

    try {
      // Создаем WebSocket соединение
      const wsUrl = `ws://${window.location.hostname}:8080/api/webrtc/signal`;
      console.log(`🔌 CREATING WEBSOCKET - URL: ${wsUrl}`);
      
      // Cleanup any existing WebSocket before creating new one
      if (wsRef.current) {
        console.log(`🧹 CLEANUP - Closing existing WebSocket (readyState: ${wsRef.current.readyState})`);
        wsRef.current.close();
        wsRef.current = null;
      }
      
      const websocket = new WebSocket(wsUrl);
      wsRef.current = websocket;
      console.log(`🔌 WEBSOCKET CREATED - readyState: ${websocket.readyState}`);
      
      // Monitor WebSocket state changes
      websocket.addEventListener('open', () => {
        console.log(`✅ WEBSOCKET OPENED - readyState: ${websocket.readyState}`);
      });
      
      websocket.addEventListener('close', (event) => {
        console.log(`❌ WEBSOCKET CLOSED - code: ${event.code}, reason: ${event.reason}, readyState: ${websocket.readyState}`);
        
        // Принудительное переподключение WebSocket через 3 секунды если не в режиме stopped
        if (status !== 'stopped') {
          console.log(`🔄 WebSocket disconnected unexpectedly - scheduling reconnect in 3 seconds`);
          setTimeout(() => {
            if (status !== 'stopped' && (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN)) {
              console.log(`🚀 FORCE WebSocket RECONNECT - attempting to reconnect`);
              // Принудительно переподключаемся
              startWebRTC();
            }
          }, 3000);
        }
      });
      
      websocket.addEventListener('error', (event) => {
        console.log(`🚨 WEBSOCKET ERROR - readyState: ${websocket.readyState}, error:`, event);
      });

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
        console.log(`🔄 WebRTC connection state changed: ${state}`);
        console.log(`🔄 Previous status was: ${status}, setting new status based on connection state`);
        
        if (state === 'connected') {
          console.log('✅ WebRTC connected successfully! Setting status to connected');
          setStatusWithLog('connected');
          setError(null);
          setServerStatus(null); // Очищаем статус сервера при успешном подключении
          setIsConnecting(false); // Важно! Сбрасываем флаг подключения
        } else if (state === 'failed' || state === 'disconnected') {
          console.log(`❌ WebRTC connection failed or disconnected: ${state}`);
          setStatusWithLog('failed');
          setError('WebRTC connection failed');
          setIsConnecting(false);
        } else if (state === 'closed') {
          console.log('🔒 WebRTC connection closed');
          setStatusWithLog('stopped');
          setIsConnecting(false);
        } else if (state === 'connecting') {
          console.log('🔄 WebRTC is connecting...');
          setStatusWithLog('connecting');
        }
      };
      
      // Дополнительное логирование ICE состояния
      peerConnection.oniceconnectionstatechange = () => {
        const iceState = peerConnection.iceConnectionState;
        setIceConnectionState(iceState);
        console.log(`🧊 ICE connection state changed: ${iceState}`);
        
        if (iceState === 'failed') {
          setError('Network connection failed (ICE)');
          console.log('❌ ICE connection failed - network issues');
        } else if (iceState === 'connected') {
          console.log('✅ ICE connection established successfully');
          // Принудительная проверка через 1 секунду после ICE connected
          setTimeout(() => {
            if (pcRef.current && pcRef.current.connectionState === 'connected' && status !== 'connected') {
              console.log('🔧 FORCE: ICE connected but status not updated, forcing status to connected');
              setStatusWithLog('connected');
              setError(null);
              setIsConnecting(false);
            }
          }, 1000);
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
        console.log('🎯 WEBSOCKET ONOPEN TRIGGERED - WebSocket connected to server');
        console.log(`🎯 WEBSOCKET STATE - readyState: ${websocket.readyState}, url: ${websocket.url}`);
        
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
          
          // Принудительная проверка статуса через 3 секунды
          setTimeout(() => {
            if (pcRef.current) {
              const currentConnectionState = pcRef.current.connectionState;
              const currentIceState = pcRef.current.iceConnectionState;
              console.log(`🔧 FORCE CHECK: Connection state: ${currentConnectionState}, ICE state: ${currentIceState}, UI status: ${status}`);
              
              if (currentConnectionState === 'connected' && status !== 'connected') {
                console.log('🔧 FORCE FIX: Connection is actually connected but UI shows different status, fixing...');
                setStatusWithLog('connected');
                setError(null);
                setIsConnecting(false);
                setServerStatus('WebRTC connected (auto-corrected)');
              } else if (currentIceState === 'connected' && currentConnectionState !== 'failed' && status === 'connecting') {
                console.log('🔧 FORCE FIX: ICE connected but UI still shows connecting, updating...');
                setStatusWithLog('connected');
                setError(null);
                setIsConnecting(false);
                setServerStatus('WebRTC connected (ICE ready)');
              }
            }
          }, 3000);
        } catch (err) {
          console.log(`WebRTC Debug: Failed to create offer: ${err.message}`);
          setError('Failed to create offer: ' + err.message);
          setStatusWithLog('failed');
          setIsConnecting(false);
        }
      };

      websocket.onmessage = async (event) => {
        try {
          const message = JSON.parse(event.data);
          console.log(`WebRTC Debug: Received: ${message.type}`);
          
          if (message.type === 'answer') {
            console.log('📨 [DIAG] RECEIVED SDP ANSWER from server');
            console.log(`📨 [DIAG] PeerConnection state: ${pcRef.current?.connectionState}`);
            console.log(`📨 [DIAG] Answer SDP length: ${message.sdp?.length || 0} chars`);
            
            if (window.debugLogUserAction) {
              window.debugLogUserAction('SDP Answer Received', 
                `PC state: ${pcRef.current?.connectionState}, SDP length: ${message.sdp?.length || 0}`);
            }
            
            if (pcRef.current && message.sdp) {
              console.log('📨 [DIAG] Setting remote description...');
              await pcRef.current.setRemoteDescription(new RTCSessionDescription({
                type: 'answer',
                sdp: message.sdp
              }));
              console.log('✅ [DIAG] Remote description set successfully');
              
              if (window.debugLogUserAction) {
                window.debugLogUserAction('SDP Answer Set', 'Remote description set successfully');
              }
            } else {
              console.log('❌ [DIAG] Cannot set remote description - missing PC or SDP');
              if (window.debugLogUserAction) {
                window.debugLogUserAction('SDP Answer Error', 'Missing PeerConnection or SDP data');
              }
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
            setStatusWithLog('failed');
            setIsConnecting(false);
          } else if (message.type === 'airplay_disconnected') {
            console.log(`WebRTC Debug: iPhone disconnected: ${message.message}`);
            setServerStatus('iPhone disconnected - waiting for reconnection...');
            setStatusWithLog('disconnected');
            // Don't set isConnecting to false - we want to keep the WebSocket open for auto-reconnect
          } else if (message.type === 'airplay_reconnecting') {
            console.log(`WebRTC Debug: iPhone reconnecting: ${message.message}`);
            setServerStatus('iPhone reconnected - starting WebRTC...');
            setStatusWithLog('connecting');
            setError(null);
          } else if (message.type === 'webrtc_ready') {
            console.log(`WebRTC Debug: WebRTC auto-reconnected: ${message.message}`);
            setServerStatus('WebRTC connected successfully');
            setStatusWithLog('connected');
            setError(null);
          } else if (message.type === 'reconnection_ready') {
            console.log('🔄 [DIAG] RECONNECTION_READY MESSAGE RECEIVED');
            console.log(`🔄 [DIAG] Current WebRTC state check:`);
            console.log(`  - status: ${status}`);
            console.log(`  - isConnecting: ${isConnecting}`);
            console.log(`  - pcRef.current: ${pcRef.current ? 'exists' : 'null'}`);
            console.log(`  - pcRef.connectionState: ${pcRef.current?.connectionState}`);
            console.log(`  - pcRef.iceConnectionState: ${pcRef.current?.iceConnectionState}`);
            console.log(`  - videoRef.current: ${videoRef.current ? 'exists' : 'null'}`);
            console.log(`  - videoRef.srcObject: ${videoRef.current?.srcObject ? 'exists' : 'null'}`);
            console.log(`  - video tracks: ${videoRef.current?.srcObject?.getTracks().length || 0}`);
            
            if (window.debugLogUserAction) {
              window.debugLogUserAction('Reconnection Ready Received', 
                `Status: ${status}, PC: ${pcRef.current?.connectionState}, Tracks: ${videoRef.current?.srcObject?.getTracks().length || 0}`);
            }
            
            // Check if WebRTC/Video is already working to prevent disruption
            const isWebRTCWorking = pcRef.current && 
              (pcRef.current.connectionState === 'connected' || 
               pcRef.current.iceConnectionState === 'connected') &&
              status === 'connected';
              
            const isVideoWorking = videoRef.current && 
              videoRef.current.srcObject && 
              videoRef.current.srcObject.getTracks().length > 0;
            
            console.log(`🔄 [DIAG] DECISION LOGIC:`);
            console.log(`  - isWebRTCWorking: ${isWebRTCWorking}`);
            console.log(`  - isVideoWorking: ${isVideoWorking}`);
            console.log(`  - shouldPreventReconnection: ${isWebRTCWorking || isVideoWorking}`);
            
            if (isWebRTCWorking || isVideoWorking) {
              console.log('🚫 [DIAG] WebRTC/Video already working - IGNORING reconnection_ready to prevent disruption');
              setServerStatus('WebRTC already connected - no reconnection needed');
              
              // Log prevented auto-reconnection
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Auto-reconnect Prevented', 'WebRTC already working - ignoring reconnection_ready signal');
              }
              
              return;
            }
            
            console.log('✅ [DIAG] WebRTC not working - proceeding with auto-reconnection');
            console.log('🚀 [DIAG] CALLING startAutoReconnectCountdown()');
            setServerStatus('iPhone reconnected - auto-reconnecting in 5 seconds');
            setStatusWithLog('ready_for_reconnect');
            setError(null);
            startAutoReconnectCountdown();
          } else if (message.type === 'uxplay_status') {
            console.log(`🔔 UxPlay Status Update: ${message.status}`);
            console.log(`   - Window ID: ${message.windowID || 'none'}`);
            console.log(`   - Size: ${message.width}x${message.height}`);
            
            if (message.status === 'connected') {
              console.log(`✅ iPhone connected to UxPlay - checking if WebRTC auto-restart needed`);
              
              // Проверяем нужно ли автоматически перезапустить WebRTC
              const shouldAutoRestart = (status === 'stopped' || status === 'error') && !isConnecting;
              console.log(`   - Current status: ${status}, isConnecting: ${isConnecting}`);
              console.log(`   - Should auto-restart: ${shouldAutoRestart}`);
              
              if (shouldAutoRestart) {
                console.log(`🚀 AUTO-RESTARTING WebRTC - iPhone reconnected to UxPlay`);
                setStatusWithLog('auto_restarting');
                setTimeout(() => {
                  startWebRTC();
                }, 1000); // Небольшая задержка для стабильности
              }
            } else if (message.status === 'disconnected') {
              console.log(`❌ iPhone disconnected from UxPlay`);
              if (isConnecting || status === 'connected') {
                console.log(`🛑 Stopping WebRTC due to UxPlay disconnect`);
                stopWebRTC();
              }
            }
          } else if (message.type === 'window_changed') {
            console.log('🪟 [DIAG] WINDOW_CHANGED MESSAGE RECEIVED');
            console.log(`🪟 [DIAG] Message: ${message.message}`);
            console.log(`🪟 [DIAG] Current WebRTC state check:`);
            console.log(`  - status: ${status}`);
            console.log(`  - isConnecting: ${isConnecting}`);
            console.log(`  - pcRef.current: ${pcRef.current ? 'exists' : 'null'}`);
            console.log(`  - pcRef.connectionState: ${pcRef.current?.connectionState}`);
            console.log(`  - videoRef.srcObject: ${videoRef.current?.srcObject ? 'exists' : 'null'}`);
            console.log(`  - video tracks: ${videoRef.current?.srcObject?.getTracks().length || 0}`);
            
            if (window.debugLogUserAction) {
              window.debugLogUserAction('Window Changed Received', 
                `Message: ${message.message}, Status: ${status}, PC: ${pcRef.current?.connectionState}`);
            }
            
            // Check if WebRTC/Video is already working to prevent disruption
            const isWebRTCWorking = pcRef.current && 
              (pcRef.current.connectionState === 'connected' || 
               pcRef.current.iceConnectionState === 'connected') &&
              status === 'connected';
              
            const isVideoWorking = videoRef.current && 
              videoRef.current.srcObject && 
              videoRef.current.srcObject.getTracks().length > 0;
            
            console.log(`🪟 [DIAG] DECISION LOGIC:`);
            console.log(`  - isWebRTCWorking: ${isWebRTCWorking}`);
            console.log(`  - isVideoWorking: ${isVideoWorking}`);
            console.log(`  - shouldPreventReconnection: ${isWebRTCWorking || isVideoWorking}`);
            
            if (isWebRTCWorking || isVideoWorking) {
              console.log('🚫 [DIAG] WebRTC/Video already working - IGNORING window_changed to prevent disruption');
              setServerStatus('WebRTC already connected - no window change reconnection needed');
              
              // Log prevented auto-reconnection
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Auto-reconnect Prevented', 'WebRTC already working - ignoring window_changed signal');
              }
              
              return;
            }
            
            console.log('✅ [DIAG] WebRTC not working - proceeding with window change reconnection');
            console.log('🚀 [DIAG] CALLING startAutoReconnectCountdown() from window_changed');
            setServerStatus('iPhone reconnected with new window - auto-reconnecting in 5 seconds');
            setStatusWithLog('ready_for_reconnect');
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
        setStatusWithLog('failed');
        setIsConnecting(false);
      };

      websocket.onclose = () => {
        console.log('WebSocket closed');
        console.log('WebRTC Debug: WebSocket connection closed by server');
        
        if (status !== 'stopped') {
          setStatusWithLog('disconnected');
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
      console.error('💥 FAILED TO START WEBRTC - Error:', err);
      console.log(`💥 ERROR DETAILS - message: ${err.message}, stack: ${err.stack}`);
      console.log(`💥 SETTING STATE - isConnecting=false, status=failed`);
      setError('Failed to start WebRTC: ' + err.message);
      setStatusWithLog('failed');
      setIsConnecting(false);
    }
  };

  // Функция остановки WebRTC соединения
  const stopWebRTC = () => {
    // Log user action
    if (window.debugLogUserAction) {
      window.debugLogUserAction('Stop WebRTC', `Stopping from status: ${status}, WebSocket connected: ${wsRef.current?.readyState === WebSocket.OPEN}`);
    }
    
    console.log('WebRTC Debug: Stopping WebRTC connection');
    
    // Отменяем автопереподключение если активно
    cancelAutoReconnect();
    
    console.log(`🛑 STOP WEBRTC - Current state: isConnecting=${isConnecting}, status=${status}`);
    
    // ИСПРАВЛЕНИЕ: Принудительно сбрасываем флаг isConnecting для предотвращения блокировки повторных подключений
    console.log(`🔧 RECONNECT FIX: Force resetting isConnecting=${isConnecting} to false to allow future connections`);
    setIsConnecting(false);
    setStatusWithLog('stopped');
    console.log(`🛑 STOP WEBRTC - Set isConnecting=false, status=stopped`);
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
    // Log component load
    if (window.debugLogUserAction) {
      window.debugLogUserAction('Page Load', 'WebRTC Stream component loaded');
    }
    
    return () => {
      if (window.debugLogUserAction) {
        window.debugLogUserAction('Page Unload', 'WebRTC Stream component unloading');
      }
      stopWebRTC();
      cancelAutoReconnect();
    };
  }, []);

  // Log page visibility changes for debugging
  useEffect(() => {
    const handleVisibilityChange = () => {
      if (window.debugLogUserAction) {
        window.debugLogUserAction('Page Visibility Change', 
          `Page is now ${document.hidden ? 'hidden' : 'visible'}`);
      }
    };

    const handlePageFocus = () => {
      if (window.debugLogUserAction) {
        window.debugLogUserAction('Page Focus', 'User focused browser tab');
      }
    };

    const handlePageBlur = () => {
      if (window.debugLogUserAction) {
        window.debugLogUserAction('Page Blur', 'User left browser tab');
      }
    };

    // Add event listeners
    document.addEventListener('visibilitychange', handleVisibilityChange);
    window.addEventListener('focus', handlePageFocus);
    window.addEventListener('blur', handlePageBlur);

    return () => {
      document.removeEventListener('visibilitychange', handleVisibilityChange);
      window.removeEventListener('focus', handlePageFocus);
      window.removeEventListener('blur', handlePageBlur);
    };
  }, []);

  return (
    <div>
      {/* Кнопки управления WebRTC */}
      <div style={{margin:'16px 0', display:'flex', gap:'12px', alignItems:'center'}}>
        <button 
          onClick={() => {
            console.log(`🖱️ START BUTTON CLICKED - isConnecting: ${isConnecting}, status: ${status}, autoReconnectCountdown: ${autoReconnectCountdown}`);
            
            // ИСПРАВЛЕНИЕ: Детальная диагностика состояния при нажатии Start
            const wsState = wsRef.current ? wsRef.current.readyState : 'null';
            const pcState = pcRef.current ? pcRef.current.connectionState : 'null';
            console.log(`🔍 RECONNECT DIAGNOSTICS - WebSocket: ${wsState}, PeerConnection: ${pcState}`);
            
            if (window.debugLogUserAction) {
              window.debugLogUserAction('Start Button Clicked', `isConnecting: ${isConnecting}, status: ${status}, WS: ${wsState}, PC: ${pcState}`);
            }
            startWebRTC();
          }}
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
          onClick={() => {
            console.log(`🖱️ STOP BUTTON CLICKED - isConnecting: ${isConnecting}, status: ${status}`);
            if (window.debugLogUserAction) {
              window.debugLogUserAction('Stop Button Clicked', `isConnecting: ${isConnecting}, status: ${status}`);
            }
            stopWebRTC();
          }}
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

        {/* ИСПРАВЛЕНИЕ: Кнопка для принудительного сброса "застрявшего" состояния */}
        {(isConnecting && status !== 'connecting' && status !== 'connected') && (
          <button 
            onClick={() => {
              console.log(`🔧 FORCE RESET CLICKED - isConnecting: ${isConnecting}, status: ${status}`);
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Force Reset', `Forcing reset from stuck state: isConnecting: ${isConnecting}, status: ${status}`);
              }
              
              // Принудительный сброс всех состояний
              setIsConnecting(false);
              setStatusWithLog('stopped');
              setError(null);
              setServerStatus(null);
              
              // Очистка всех соединений
              if (wsRef.current) {
                wsRef.current.close();
                wsRef.current = null;
              }
              if (pcRef.current) {
                pcRef.current.close();
                pcRef.current = null;
              }
              
              console.log(`🔧 FORCE RESET COMPLETE - state reset to allow new connections`);
            }}
            style={{
              padding:'8px 16px',
              backgroundColor: '#fd7e14',
              color: 'white',
              border: 'none',
              borderRadius:'4px',
              cursor: 'pointer',
              fontSize: '12px'
            }}
            title="Принудительно сбросить застрявшее состояние"
          >
            Force Reset
          </button>
        )}

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
            onLoadStart={() => {
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Video Event', 'loadstart - Started loading video data');
              }
            }}
            onCanPlay={() => {
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Video Event', 'canplay - Video ready to start playing');
              }
            }}
            onPlay={() => {
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Video Event', 'play - Video started playing');
              }
            }}
            onPause={() => {
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Video Event', 'pause - Video paused');
              }
            }}
            onEnded={() => {
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Video Event', 'ended - Video playback ended');
              }
            }}
            onError={(e) => {
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Video Event', `error - Video error: ${e.target.error?.message || 'Unknown error'}`);
              }
            }}
            onStalled={() => {
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Video Event', 'stalled - Video playback stalled');
              }
            }}
            onSuspend={() => {
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Video Event', 'suspend - Video loading suspended');
              }
            }}
            onWaiting={() => {
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Video Event', 'waiting - Video waiting for data');
              }
            }}
          />
        </div>
      </div>
      
      {/* Debug Panel */}
      <DebugPanel />
    </div>
  );
} 