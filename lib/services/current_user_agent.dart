import 'current_user_agent_stub.dart'
    if (dart.library.html) 'current_user_agent_web.dart' as impl;

String currentUserAgent() => impl.currentUserAgent();
