//
//  WaifuX Steam service.
//  The interactive authentication flow is adapted from MirageWallpaper.
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

using SteamKit2.Authentication;

namespace WaifuXSteamService;

internal sealed class InteractiveAuthenticator : IAuthenticator
{
    private readonly ProtocolWriter writer;
    private readonly bool preferGuardCode;
    private readonly object gate = new();
    private TaskCompletionSource<string>? pendingCode;
    private volatile bool waitingForDeviceConfirmation;
    private string? initialCode;

    public bool IsWaitingForDeviceConfirmation => waitingForDeviceConfirmation;

    public InteractiveAuthenticator(ProtocolWriter writer, bool preferGuardCode)
    {
        this.writer = writer;
        this.preferGuardCode = preferGuardCode;
    }

    public void SetInitialCode(string? code)
    {
        initialCode = string.IsNullOrWhiteSpace(code) ? null : code.Trim();
    }

    public Task<string> GetDeviceCodeAsync(bool previousCodeWasIncorrect)
    {
        waitingForDeviceConfirmation = false;
        if (!previousCodeWasIncorrect && initialCode is { Length: > 0 })
        {
            var code = initialCode;
            initialCode = null;
            return Task.FromResult(code);
        }
        return WaitForCode("mobileCode", previousCodeWasIncorrect);
    }

    public Task<string> GetEmailCodeAsync(string email, bool previousCodeWasIncorrect)
    {
        waitingForDeviceConfirmation = false;
        if (!previousCodeWasIncorrect && initialCode is { Length: > 0 })
        {
            var code = initialCode;
            initialCode = null;
            return Task.FromResult(code);
        }
        return WaitForCode("emailCode", previousCodeWasIncorrect);
    }

    public Task<bool> AcceptDeviceConfirmationAsync()
    {
        if (preferGuardCode) return Task.FromResult(false);
        waitingForDeviceConfirmation = true;
        writer.AuthState("waitingMobile");
        return Task.FromResult(true);
    }

    public bool Submit(string code)
    {
        TaskCompletionSource<string>? source;
        lock (gate)
        {
            source = pendingCode;
            pendingCode = null;
        }
        return source?.TrySetResult(code) == true;
    }

    public void Cancel()
    {
        waitingForDeviceConfirmation = false;
        TaskCompletionSource<string>? source;
        lock (gate)
        {
            source = pendingCode;
            pendingCode = null;
        }
        source?.TrySetCanceled();
    }

    private Task<string> WaitForCode(string state, bool previousCodeRejected)
    {
        var source = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate) pendingCode = source;
        writer.AuthState(state, previousCodeRejected: previousCodeRejected);
        return source.Task;
    }
}
