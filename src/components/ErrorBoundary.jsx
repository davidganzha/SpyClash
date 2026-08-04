import { Component } from "react";

export default class ErrorBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error) {
    return { hasError: true, error };
  }

  componentDidCatch(error, info) {
    console.error("ErrorBoundary caught:", error, info);
  }

  render() {
    if (this.state.hasError) {
      return (
        <div style={{
          position: "fixed", inset: 0, background: "#000",
          display: "flex", flexDirection: "column",
          alignItems: "center", justifyContent: "center",
          fontFamily: "monospace", padding: 24
        }}>
          <div style={{ color: "#e53535", fontSize: 28, marginBottom: 16 }}>⚠</div>
          <div style={{ color: "#888", fontSize: 12, letterSpacing: 3, marginBottom: 12 }}>APP CRASH</div>
          <div style={{
            color: "#444", fontSize: 11, letterSpacing: 1, marginBottom: 24,
            maxWidth: 480, textAlign: "center", lineHeight: 1.6,
            wordBreak: "break-all"
          }}>
            {this.state.error?.message || "Unknown error"}
          </div>
          <button
            onClick={() => window.location.reload()}
            style={{
              background: "#e53535", color: "#fff", border: "none",
              padding: "10px 28px", fontSize: 12, letterSpacing: 3,
              fontFamily: "monospace", cursor: "pointer"
            }}
          >RETRY</button>
        </div>
      );
    }
    return this.props.children;
  }
}