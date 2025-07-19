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
        
        // Финальная проверка перед автопереподключением
        const isWebRTCWorking = pcRef.current && 
          (pcRef.current.connectionState === 'connected' || 
           pcRef.current.iceConnectionState === 'connected') &&
          status === 'connected';
           
        const isVideoWorking = videoRef.current && 
          videoRef.current.srcObject && 
          videoRef.current.srcObject.getTracks().length > 0;
        
                 if (isWebRTCWorking || isVideoWorking) {
           console.log('🚫 COUNTDOWN FINAL CHECK: WebRTC/Video working - CANCELLING auto-reconnection');
           setServerStatus('Auto-reconnection cancelled - WebRTC already working');
           
           // Log countdown cancellation
           if (window.debugLogUserAction) {
             window.debugLogUserAction('Auto-reconnect Cancelled', 'Final check detected working WebRTC - countdown cancelled');
           }
           
           return;
         }
        
        console.log('✅ COUNTDOWN FINAL CHECK: WebRTC not working - proceeding with auto-reconnection');
        console.log('WebRTC Debug: Auto-reconnecting after countdown');
        
        // Log automatic reconnection
        if (window.debugLogUserAction) {
          window.debugLogUserAction('Auto-reconnect Triggered', 'System automatically reconnecting after 5 second countdown');
        }
        
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
    // Log user action if called manually (not automatically)
    if (autoReconnectCountdown !== null && window.debugLogUserAction) {
      window.debugLogUserAction('Cancel Auto-reconnect', `Cancelled with ${autoReconnectCountdown} seconds remaining`);
    }
    
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
    setStatusWithLog('connecting');
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
          setStatusWithLog('connected');
          setError(null);
          setServerStatus(null);
          console.log('WebRTC connected successfully!');
        } else if (state === 'failed' || state === 'disconnected') {
          setStatusWithLog('failed');
          setError('WebRTC connection failed');
          setIsConnecting(false);
          console.error('WebRTC connection failed or disconnected');
        } else if (state === 'closed') {
          setStatusWithLog('stopped');
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
      const wsUrl = `ws://${window.location.host}/api/webrtc/signal`;
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
            console.log(`WebRTC Debug: System ready for reconnection: ${message.message}`);
            
            // Детальная диагностика состояния соединения
            const pcExists = !!pcRef.current;
            const connectionState = pcRef.current ? pcRef.current.connectionState : 'no-pc';
            const iceState = pcRef.current ? pcRef.current.iceConnectionState : 'no-pc';
            const currentStatus = status;
            const videoPlaying = videoRef.current && videoRef.current.srcObject && !videoRef.current.paused;
            
            console.log(`🔍 RECONNECTION_READY CHECK:`);
            console.log(`   - pcRef exists: ${pcExists}`);
            console.log(`   - connectionState: ${connectionState}`);
            console.log(`   - iceConnectionState: ${iceState}`);
            console.log(`   - UI status: ${currentStatus}`);
            console.log(`   - Video playing: ${videoPlaying}`);
            
            // Улучшенная проверка - проверяем несколько условий
            const isWebRTCWorking = pcRef.current && 
              (pcRef.current.connectionState === 'connected' || 
               pcRef.current.iceConnectionState === 'connected') &&
              status === 'connected';
               
            const isVideoWorking = videoRef.current && 
              videoRef.current.srcObject && 
              videoRef.current.srcObject.getTracks().length > 0;
            
            if (isWebRTCWorking || isVideoWorking) {
              console.log('🚫 WebRTC/Video already working - IGNORING reconnection_ready to prevent disruption');
              setServerStatus('WebRTC already connected - no reconnection needed');
              
              // Log prevented auto-reconnection
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Auto-reconnect Prevented', 'WebRTC already working - ignoring reconnection_ready signal');
              }
              
              return;
            }
            
            console.log('✅ WebRTC not working - proceeding with auto-reconnection');
            setServerStatus('iPhone reconnected - auto-reconnecting in 5 seconds');
            setStatusWithLog('ready_for_reconnect');
            setError(null);
            startAutoReconnectCountdown();
          } else if (message.type === 'window_changed') {
            console.log(`WebRTC Debug: iPhone window changed: ${message.message}`);
            
            // Детальная диагностика состояния соединения
            const pcExists = !!pcRef.current;
            const connectionState = pcRef.current ? pcRef.current.connectionState : 'no-pc';
            const iceState = pcRef.current ? pcRef.current.iceConnectionState : 'no-pc';
            const currentStatus = status;
            const videoPlaying = videoRef.current && videoRef.current.srcObject && !videoRef.current.paused;
            
            console.log(`🔍 WINDOW_CHANGED CHECK:`);
            console.log(`   - pcRef exists: ${pcExists}`);
            console.log(`   - connectionState: ${connectionState}`);
            console.log(`   - iceConnectionState: ${iceState}`);
            console.log(`   - UI status: ${currentStatus}`);
            console.log(`   - Video playing: ${videoPlaying}`);
            
            // Улучшенная проверка - проверяем несколько условий
            const isWebRTCWorking = pcRef.current && 
              (pcRef.current.connectionState === 'connected' || 
               pcRef.current.iceConnectionState === 'connected') &&
              status === 'connected';
               
            const isVideoWorking = videoRef.current && 
              videoRef.current.srcObject && 
              videoRef.current.srcObject.getTracks().length > 0;
            
            if (isWebRTCWorking || isVideoWorking) {
              console.log('🚫 WebRTC/Video already working - IGNORING window_changed to prevent disruption');
              setServerStatus('WebRTC already connected - no window change reconnection needed');
              
              // Log prevented auto-reconnection
              if (window.debugLogUserAction) {
                window.debugLogUserAction('Auto-reconnect Prevented', 'WebRTC already working - ignoring window_changed signal');
              }
              
              return;
            }
            
            console.log('✅ WebRTC not working - proceeding with window change reconnection');
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