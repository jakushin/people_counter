import React, { useState, useEffect, useRef } from 'react';

export default function DebugPanel() {
  const [messages, setMessages] = useState([]);
  const [isConnected, setIsConnected] = useState(false);
  const [error, setError] = useState(null);
  const [isSaving, setIsSaving] = useState(false);
  const [isLoggingEnabled, setIsLoggingEnabled] = useState(false);
  const [isStarting, setIsStarting] = useState(false);
  const [isStopping, setIsStopping] = useState(false);
  const messagesEndRef = useRef(null);
  const wsRef = useRef(null);

  // Function to log user actions to debug console
  const logUserAction = (action, details = '') => {
    const timestamp = new Date().toLocaleTimeString('en-GB', { 
      hour12: false, 
      hour: '2-digit', 
      minute: '2-digit', 
      second: '2-digit',
      fractionalSecondDigits: 3 
    });
    
    const userActionMessage = {
      timestamp: `[${timestamp}]`,
      level: '[USER]',
      category: '[ACTION]',
      message: action,
      details: details ? ` | ${details}` : ''
    };
    
    // Add directly to local messages for immediate display
    setMessages(prev => [...prev, userActionMessage]);
    
    // Also log to browser console for additional debugging
    console.log(`👤 USER ACTION: ${action}${details ? ` | ${details}` : ''}`);
  };

  // Expose logUserAction globally for WebRTCStream to use
  useEffect(() => {
    window.debugLogUserAction = logUserAction;
    return () => {
      delete window.debugLogUserAction;
    };
  }, [logUserAction]);

  // Auto-scroll to bottom when new messages arrive
  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  };

  useEffect(() => {
    scrollToBottom();
  }, [messages]);

  // Connect to debug WebSocket
  useEffect(() => {
    const connectDebugWebSocket = () => {
      const wsUrl = `ws://${window.location.hostname}:8080/api/debug/stream`;
      
      try {
        const ws = new WebSocket(wsUrl);
        wsRef.current = ws;

        ws.onopen = () => {
          console.log('Debug WebSocket connected');
          setIsConnected(true);
          setError(null);
        };

        ws.onmessage = (event) => {
          try {
            const message = JSON.parse(event.data);
            setMessages(prev => [...prev, message]);
            
            // Keep only last 500 messages to prevent memory issues
            setMessages(prev => prev.slice(-500));
          } catch (err) {
            console.error('Failed to parse debug message:', err);
          }
        };

        ws.onclose = () => {
          console.log('Debug WebSocket disconnected');
          setIsConnected(false);
          
          // Auto-reconnect after 3 seconds
          setTimeout(connectDebugWebSocket, 3000);
        };

        ws.onerror = (err) => {
          console.error('Debug WebSocket error:', err);
          setError('WebSocket connection failed');
          setIsConnected(false);
        };

      } catch (err) {
        console.error('Failed to create debug WebSocket:', err);
        setError('Failed to create WebSocket connection');
      }
    };

    connectDebugWebSocket();

    // Cleanup on unmount
    return () => {
      if (wsRef.current) {
        wsRef.current.close();
      }
    };
  }, []);

  // Save debug log to file
  const saveDebugLog = async () => {
    logUserAction('Save Debug Log', 'Attempting to save debug.txt');
    setIsSaving(true);
    try {
      const response = await fetch(`http://${window.location.hostname}:8080/api/debug/save`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      });

      if (response.ok) {
        const result = await response.json();
        // Add a system message to show save success
        const saveMessage = {
          timestamp: new Date(),
          level: 'SUCCESS',
          category: 'DEBUG',
          event: 'log_saved',
          message: `Debug log saved to ${result.file}`,
          details: { filename: result.file }
        };
        setMessages(prev => [...prev, saveMessage]);
        logUserAction('Save Debug Log', `SUCCESS: File saved as ${result.file}`);
      } else {
        throw new Error('Failed to save debug log');
      }
    } catch (err) {
      console.error('Failed to save debug log:', err);
      setError('Failed to save debug log: ' + err.message);
      logUserAction('Save Debug Log', `ERROR: ${err.message}`);
    } finally {
      setIsSaving(false);
    }
  };

  // Start debug logging
  const startDebugLogging = async () => {
    logUserAction('Start Debug Logging', 'Enabling debug logging on backend');
    setIsStarting(true);
    try {
      const response = await fetch(`http://${window.location.hostname}:8080/api/debug/start`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      });

      if (response.ok) {
        const result = await response.json();
        setIsLoggingEnabled(true);
        setError(null);
        logUserAction('Start Debug Logging', 'SUCCESS: Debug logging enabled');
      } else {
        throw new Error('Failed to start debug logging');
      }
    } catch (err) {
      console.error('Failed to start debug logging:', err);
      setError('Failed to start debug logging: ' + err.message);
      logUserAction('Start Debug Logging', `ERROR: ${err.message}`);
    } finally {
      setIsStarting(false);
    }
  };

  // Stop debug logging
  const stopDebugLogging = async () => {
    logUserAction('Stop Debug Logging', 'Disabling debug logging on backend');
    setIsStopping(true);
    try {
      const response = await fetch(`http://${window.location.hostname}:8080/api/debug/stop`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      });

      if (response.ok) {
        const result = await response.json();
        setIsLoggingEnabled(false);
        setError(null);
        logUserAction('Stop Debug Logging', 'SUCCESS: Debug logging disabled');
      } else {
        throw new Error('Failed to stop debug logging');
      }
    } catch (err) {
      console.error('Failed to stop debug logging:', err);
      setError('Failed to stop debug logging: ' + err.message);
      logUserAction('Stop Debug Logging', `ERROR: ${err.message}`);
    } finally {
      setIsStopping(false);
    }
  };

  // Clear debug messages
  const clearMessages = () => {
    const messageCount = messages.length;
    logUserAction('Clear Debug Messages', `Cleared ${messageCount} messages from console`);
    setMessages([]);
  };

  // Format timestamp
  const formatTime = (timestamp) => {
    const date = new Date(timestamp);
    return date.toLocaleTimeString('en-US', { 
      hour12: false, 
      hour: '2-digit', 
      minute: '2-digit', 
      second: '2-digit',
      fractionalSecondDigits: 3
    });
  };

  // Get level color
  const getLevelColor = (level) => {
    switch (level) {
      case 'SUCCESS': return '#28a745';
      case 'ERROR': return '#dc3545';
      case 'WARNING': return '#ffc107';
      case 'INFO': return '#17a2b8';
      default: return '#6c757d';
    }
  };

  // Get category color
  const getCategoryColor = (category) => {
    switch (category) {
      case 'WEBRTC': return '#007bff';
      case 'WEBSOCKET': return '#6f42c1';
      case 'AUTO_RECONNECT': return '#fd7e14';
      case 'AIRPLAY': return '#20c997';
      case 'FFMPEG': return '#e83e8c';
      case 'SYSTEM': return '#6c757d';
      case 'DEBUG': return '#343a40';
      case '[ACTION]': return '#28a745'; // User actions in green
      default: return '#6c757d';
    }
  };

  // Get level color  
  const getLevelColorForUser = (level) => {
    switch (level) {
      case '[USER]': return '#17a2b8'; // User level in cyan
      case 'SUCCESS': return '#28a745';
      case 'ERROR': return '#dc3545';
      case 'WARNING': return '#ffc107';
      case 'INFO': return '#17a2b8';
      default: return '#6c757d';
    }
  };

  return (
    <div style={{ 
      marginTop: '16px',
      border: '1px solid #ddd', 
      borderRadius: '4px',
      backgroundColor: '#f8f9fa',
      height: '400px',
      display: 'flex',
      flexDirection: 'column'
    }}>
      {/* Header */}
      <div style={{
        padding: '8px 12px',
        borderBottom: '1px solid #ddd',
        backgroundColor: '#e9ecef',
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'center',
        fontWeight: 'bold',
        fontSize: '14px'
      }}>
                 <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
           <span>Debug Console</span>
           <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
             <div style={{
               width: '8px',
               height: '8px',
               borderRadius: '50%',
               backgroundColor: isConnected ? '#28a745' : '#dc3545'
             }}></div>
             <span style={{ 
               fontSize: '12px', 
               color: isConnected ? '#28a745' : '#dc3545' 
             }}>
               {isConnected ? 'Connected' : 'Disconnected'}
             </span>
           </div>
           <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
             <div style={{
               width: '8px',
               height: '8px',
               borderRadius: '50%',
               backgroundColor: isLoggingEnabled ? '#ffc107' : '#6c757d'
             }}></div>
             <span style={{ 
               fontSize: '12px', 
               color: isLoggingEnabled ? '#ffc107' : '#6c757d' 
             }}>
               {isLoggingEnabled ? 'Logging' : 'Stopped'}
             </span>
           </div>
           {messages.length > 0 && (
             <span style={{ fontSize: '12px', color: '#6c757d' }}>
               ({messages.length} messages)
             </span>
           )}
         </div>
        
        <div style={{ display: 'flex', gap: '8px' }}>
          {!isLoggingEnabled ? (
            <button
              onClick={startDebugLogging}
              disabled={isStarting}
              style={{
                padding: '4px 8px',
                fontSize: '12px',
                backgroundColor: isStarting ? '#6c757d' : '#28a745',
                color: 'white',
                border: 'none',
                borderRadius: '3px',
                cursor: isStarting ? 'not-allowed' : 'pointer'
              }}
            >
              {isStarting ? 'Starting...' : 'Start Debug'}
            </button>
          ) : (
            <button
              onClick={stopDebugLogging}
              disabled={isStopping}
              style={{
                padding: '4px 8px',
                fontSize: '12px',
                backgroundColor: isStopping ? '#6c757d' : '#dc3545',
                color: 'white',
                border: 'none',
                borderRadius: '3px',
                cursor: isStopping ? 'not-allowed' : 'pointer'
              }}
            >
              {isStopping ? 'Stopping...' : 'Stop Debug'}
            </button>
          )}
          
          <button
            onClick={clearMessages}
            disabled={messages.length === 0}
            style={{
              padding: '4px 8px',
              fontSize: '12px',
              backgroundColor: messages.length === 0 ? '#6c757d' : '#6c757d',
              color: 'white',
              border: 'none',
              borderRadius: '3px',
              cursor: messages.length === 0 ? 'not-allowed' : 'pointer'
            }}
          >
            Clear
          </button>
          
          <button
            onClick={saveDebugLog}
            disabled={isSaving || messages.length === 0}
            style={{
              padding: '4px 8px',
              fontSize: '12px',
              backgroundColor: (isSaving || messages.length === 0) ? '#6c757d' : '#ffc107',
              color: 'white',
              border: 'none',
              borderRadius: '3px',
              cursor: (isSaving || messages.length === 0) ? 'not-allowed' : 'pointer'
            }}
          >
            {isSaving ? 'Saving...' : 'Save debug.txt'}
          </button>
        </div>
      </div>

      {/* Error display */}
      {error && (
        <div style={{
          padding: '8px 12px',
          backgroundColor: '#f8d7da',
          color: '#721c24',
          fontSize: '12px',
          borderBottom: '1px solid #ddd'
        }}>
          {error}
        </div>
      )}

      {/* Messages container */}
      <div style={{
        flex: 1,
        overflowY: 'auto',
        padding: '8px',
        fontSize: '11px',
        fontFamily: 'Monaco, Consolas, "Courier New", monospace',
        lineHeight: '1.4',
        backgroundColor: '#ffffff'
      }}>
                 {messages.length === 0 ? (
           <div style={{ 
             textAlign: 'center', 
             color: '#6c757d', 
             marginTop: '50px',
             fontSize: '14px'
           }}>
             {isLoggingEnabled ? 
               'Debug logging active. Interact with WebRTC to see live diagnostics.' :
               'Debug logging stopped. Click "Start Debug" to begin logging.'
             }
           </div>
         ) : (
          messages.map((msg, index) => (
            <div key={index} style={{ marginBottom: '2px' }}>
              <span style={{ color: '#6c757d' }}>
                {msg.timestamp || `[${formatTime(msg.timestamp)}]`}
              </span>
              {' '}
              <span style={{ 
                color: msg.level === '[USER]' ? getLevelColorForUser(msg.level) : getLevelColor(msg.level),
                fontWeight: 'bold'
              }}>
                {msg.level}
              </span>
              {' '}
              <span style={{ 
                color: getCategoryColor(msg.category),
                fontWeight: 'bold'
              }}>
                {msg.category}{msg.event ? `/${msg.event}` : ''}
              </span>
              {' '}
              <span style={{ color: '#212529' }}>
                {msg.message}
              </span>
              {/* Handle both string and object details */}
              {msg.details && (
                <span style={{ color: '#6c757d', fontSize: '10px' }}>
                  {typeof msg.details === 'string' ? 
                    msg.details : 
                    Object.keys(msg.details).length > 0 ? (
                      ' | ' + Object.entries(msg.details).map(([key, value]) => 
                        `${key}=${JSON.stringify(value)}`
                      ).join(', ')
                    ) : ''
                  }
                </span>
              )}
            </div>
          ))
        )}
        <div ref={messagesEndRef} />
      </div>
    </div>
  );
} 