﻿using Microsoft.Azure.WebJobs;
using Microsoft.Azure.WebJobs.Host;
using Microsoft.Azure.WebJobs.Host.Timers;
using Microsoft.Azure.WebJobs.Script;
using System;
using System.Collections.Generic;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Threading.Tasks;

namespace WebJobs.Script.K8Host
{
    public class K8ScriptHostExceptionHandler : IWebJobsExceptionHandler
    {
        private readonly ScriptHostManager _manager;

        public K8ScriptHostExceptionHandler(ScriptHostManager manager)
        {
            _manager = manager ?? throw new ArgumentNullException(nameof(manager));
        }

        public void Initialize(JobHost host)
        {         
        }

        public async Task OnTimeoutExceptionAsync(ExceptionDispatchInfo exceptionInfo, TimeSpan timeoutGracePeriod)
        {
            var timeoutException = exceptionInfo.SourceException as FunctionTimeoutException;

            if (timeoutException?.Task != null)
            {
                // We may double the timeoutGracePeriod here by first waiting to see if the iniital
                // function task that started the exception has completed.
                Task completedTask = await Task.WhenAny(timeoutException.Task, Task.Delay(timeoutGracePeriod));

                // If the function task has completed, simply return. The host has already logged the timeout.
                if (completedTask == timeoutException.Task)
                {
                    return;
                }
            }

            LogErrorAndFlush("A function timeout has occurred. Host is shutting down.", exceptionInfo.SourceException);

            // We can't wait on this as it may cause a deadlock if the timeout was fired
            // by a Listener that cannot stop until it has completed.
            Task ignoreTask = _manager.StopAsync();

            // Give the manager and all running tasks some time to shut down gracefully.
            await Task.Delay(timeoutGracePeriod);

            // TODO: FACAVAL - PASS ENVIRONMENT AND INITIATE SHUTDWON
            // HostingEnvironment.InitiateShutdown();
        }

        public Task OnUnhandledExceptionAsync(ExceptionDispatchInfo exceptionInfo)
        {
            LogErrorAndFlush("An unhandled exception has occurred. Host is shutting down.", exceptionInfo.SourceException);

            // TODO: FACAVAL - PASS ENVIRONMENT AND INITIATE SHUTDWON
            return Task.CompletedTask;
        }

        private void LogErrorAndFlush(string message, Exception exception)
        {
            _manager.Instance.TraceWriter.Error(message, exception);
            _manager.Instance.TraceWriter.Flush();
        }
    }
}
