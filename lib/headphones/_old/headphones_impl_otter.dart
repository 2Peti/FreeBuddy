import 'dart:async';
import 'dart:typed_data';

import 'package:rxdart/rxdart.dart';
import 'package:stream_channel/stream_channel.dart';

import '../../logger.dart';
import '../huawei/mbb.dart';
import 'headphones_base.dart';
import 'headphones_data_objects.dart';

class HeadphonesImplOtter extends HeadphonesBase {
  final StreamChannel<Uint8List> connection;
  final _batteryStreamCtrl = BehaviorSubject<HeadphonesBatteryData>();
  final _ancStreamCtrl = BehaviorSubject<HeadphonesAncMode>();
  final _autoPauseStreamCtrl = BehaviorSubject<bool>();
  final _gestureSettingsStreamCtrl =
      BehaviorSubject<HeadphonesGestureSettings>();
  late final GenericHeadphoneCommands _headphoneInterface;

  /// This watches if we are still missing any info and re-requests it
  late StreamSubscription _watchdogStreamSub;

  HeadphonesImplOtter(this.connection, this.name, this.alias) {
    if (name.contains('4i')) {
      _headphoneInterface = Freebuds4iCommands();
    } else if (name.contains('3i')) {
      _headphoneInterface = Freebuds3iCommands();
    } else {
      throw ("Unknown headphone model, cannot determine required opcodes, throwing");
    }

    connection.stream.listen((event) {
      List<MbbCommand>? commands;
      try {
        commands = MbbCommand.fromPayload(event);
      } catch (e, s) {
        logg.e("mbb parsing error", error: e, stackTrace: s);
      }
      for (final cmd in commands ?? <MbbCommand>[]) {
        // FILTER THE SHIT OUT
        if (!(cmd.serviceId == 10 && cmd.commandId == 13)) {
          logg.t("📥 Received mbb cmd: $cmd");
        }
        try {
          _evalMbbCommand(cmd);
        } on RangeError catch (e, s) {
          logg.e('Error while parsing mbb cmd - (probably missing bytes)',
              error: e, stackTrace: s);
        }
      }
    }, onDone: () async {
      _batteryStreamCtrl.close();
      _ancStreamCtrl.close();
      _autoPauseStreamCtrl.close();
      _gestureSettingsStreamCtrl.close();
      _watchdogStreamSub.cancel();
    });
    _initRequestInfo();
    _watchdogStreamSub =
        Stream.periodic(const Duration(seconds: 3)).listen((_) {
      if ([
        batteryData.valueOrNull,
        ancMode.valueOrNull,
        // 3i doesn't even support querying the autopause status, so let's just build a workaround
        // so that the app doesn't futilely spam the headphones to get the autopause mode
        (_headphoneInterface.runtimeType == Freebuds3iCommands ? autoPause.valueOrNull : true),
        gestureSettings.valueOrNull?.doubleTapLeft,
        gestureSettings.valueOrNull?.doubleTapRight,
        gestureSettings.valueOrNull?.holdBothToggledAncModes,
      ].any((e) => e == null)) {
        _initRequestInfo();
      }
    });
  }

  void _evalMbbCommand(MbbCommand cmd) {
    final lastGestures = _gestureSettingsStreamCtrl.valueOrNull ??
        const HeadphonesGestureSettings();
    if (cmd.serviceId == 43 && (cmd.commandId == 42 || cmd.commandId == 5) && cmd.args.containsKey(1)) {
      late HeadphonesAncMode newMode;
      // TODO: Add some constants for this globally
      // because 0 1 and 2 seem to be constant bytes representing the modes
      // and once again, 3i just doesn't do it the way 4i does.
      final modeByte = _headphoneInterface.runtimeType == Freebuds4iCommands ? cmd.args[1]![1] : cmd.args[1]![0];
      if (modeByte == 1) {
        newMode = HeadphonesAncMode.noiseCancel;
      } else if (modeByte == 0) {
        newMode = HeadphonesAncMode.off;
      } else if (modeByte == 2) {
        newMode = HeadphonesAncMode.awareness;
      } else {
        logg.e("Unknown ANC mode: ${cmd.args[1]}");
        return;
      }
      _ancStreamCtrl.add(newMode);
    } else if (cmd.serviceId == 1 &&
        (cmd.commandId == 39 || cmd.commandId == 8) &&
        cmd.args.length >= 3) {
      final level = cmd.args[2];
      final status = cmd.args[3];
      if (level == null || status == null) {
        logg.e("Battery data is missing level or status");
        return;
      }
      _batteryStreamCtrl.add(HeadphonesBatteryData(
        level[0] == 0 ? null : level[0],
        level[1] == 0 ? null : level[1],
        level[2] == 0 ? null : level[2],
        status[0] == 1,
        status[1] == 1,
        status[2] == 1,
      ));
    } else if (cmd.serviceId == 43 &&
        cmd.commandId == 17 &&
        cmd.args.containsKey(1)) {
      _autoPauseStreamCtrl.add(cmd.args[1]![0] == 1);
    } else if (cmd.serviceId == 1 && cmd.commandId == 32) {
      _gestureSettingsStreamCtrl.add(
        lastGestures.copyWith(
          doubleTapLeft: cmd.args[1] != null
              ? _headphoneInterface.fromMbbValue(
                  cmd.args[1]![0], _headphoneInterface.doubleTapCommands)
              : lastGestures.doubleTapLeft,
          doubleTapRight: cmd.args[2] != null
              ? _headphoneInterface.fromMbbValue(
                  cmd.args[2]![0], _headphoneInterface.doubleTapCommands)
              : lastGestures.doubleTapRight,
        ),
      );
    }

    if (_headphoneInterface.runtimeType == Freebuds3iCommands) {
      if ((cmd.serviceId == 43 && cmd.commandId == 23)) {
        _gestureSettingsStreamCtrl.add(
          lastGestures.copyWith(
            //because there is no separate way to queue just the anc/nothing mode on long press,
            //we need to do this mental gymnastics (if hold != 255 (not off), force the holdBoth to enabled and process the actual opcode later)
            //by the way, the first argument doesn't seem to do anything no matter what you set it to, only the second matters.
            holdBoth: (cmd.args[2]![0] != 255)
                ? HeadphonesGestureHold.cycleAnc
                : (cmd.args[2]![0] == 255)
                    ? HeadphonesGestureHold.nothing
                    : lastGestures.holdBoth,
            holdBothToggledAncModes: (cmd.args[2]![0] != 255 &&
                    cmd.args[2] != null)
                ? _headphoneInterface.gestureHoldFromMbbValue(cmd.args[2]![0])
                : lastGestures.holdBothToggledAncModes,
          ),
        );
      }
    } else if (_headphoneInterface.runtimeType == Freebuds4iCommands) {
      if ((cmd.serviceId == 43 && cmd.commandId == 23)) {
        _gestureSettingsStreamCtrl.add(
          lastGestures.copyWith(
            holdBoth: (cmd.args[1] != null)
                ? _headphoneInterface.fromMbbValue(
                    cmd.args[1]![0], _headphoneInterface.holdCommands)
                : lastGestures.holdBoth,
          ),
        );
      } else if (cmd.serviceId == 43 && cmd.commandId == 25) {
        _gestureSettingsStreamCtrl.add(
          lastGestures.copyWith(
            holdBothToggledAncModes: (cmd.args[1] != null)
                ? _headphoneInterface.gestureHoldFromMbbValue(cmd.args[1]![0])
                : lastGestures.holdBothToggledAncModes,
          ),
        );
      }
    }
  }

  Future<void> _initRequestInfo() async {
    await _sendMbb(_headphoneInterface.requestBattery);
    await _sendMbb(_headphoneInterface.requestAnc);
    await _sendMbb(_headphoneInterface.requestAutoPause);
    await _sendMbb(_headphoneInterface.requestGestureDoubleTap);
    await _sendMbb(_headphoneInterface.requestGestureHold);
    await _sendMbb(_headphoneInterface.requestGestureHoldToggledAncModes);
  }

  // TODO: some .flush() for this
  Future<void> _sendMbb(MbbCommand comm) async {
    logg.t("⬆ Sending mbb cmd: $comm");
    connection.sink.add(comm.toPayload());
  }


  @override
  final String name;

  @override
  final String? alias;

  @override
  ValueStream<HeadphonesBatteryData> get batteryData =>
      _batteryStreamCtrl.stream;

  @override
  ValueStream<HeadphonesAncMode> get ancMode => _ancStreamCtrl.stream;

  @override
  Future<void> setAncMode(HeadphonesAncMode mode) async {
    late MbbCommand comm;
    switch (mode) {
      case HeadphonesAncMode.noiseCancel:
        comm = _headphoneInterface.ancNoiseCancel;
        break;
      case HeadphonesAncMode.off:
        comm = _headphoneInterface.ancOff;
        break;
      case HeadphonesAncMode.awareness:
        comm = _headphoneInterface.ancAware;
        break;
    }
    await _sendMbb(comm);
    //needed to avoid UI lag after changing modes
    await _sendMbb(_headphoneInterface.requestAnc);
  }

  @override
  ValueStream<bool> get autoPause => _autoPauseStreamCtrl.stream;

  @override
  Future<void> setAutoPause(bool enabled) async {
    await _sendMbb(enabled
        ? _headphoneInterface.autoPauseOn
        : _headphoneInterface.autoPauseOff);
    await _sendMbb(_headphoneInterface.requestAutoPause);
  }

  @override
  ValueStream<HeadphonesGestureSettings> get gestureSettings =>
      _gestureSettingsStreamCtrl.stream;

  /// This function welcomes you to send [settings] object with null values -
  /// it will only send headphones commands for non-null values, so we don't
  /// waste time 👍
  @override
  Future<void> setGestureSettings(HeadphonesGestureSettings settings) async {
    // double tap
    if (settings.doubleTapLeft != null) {
      await _sendMbb(
          _headphoneInterface.gestureDoubleTapLeft(settings.doubleTapLeft!));
    }
    if (settings.doubleTapRight != null) {
      await _sendMbb(
          _headphoneInterface.gestureDoubleTapRight(settings.doubleTapRight!));
    }
    if (settings.doubleTapLeft != null || settings.doubleTapRight != null) {
      await _sendMbb(_headphoneInterface.requestGestureDoubleTap);
    }
    // hold
    if (settings.holdBoth != null) {
      await _sendMbb(_headphoneInterface.gestureHold(settings.holdBoth!));
      await _sendMbb(_headphoneInterface.requestGestureHold);
    }
    if (settings.holdBothToggledAncModes != null) {
      await _sendMbb(_headphoneInterface
          .gestureHoldToggledAncModes(settings.holdBothToggledAncModes!));
      await _sendMbb(_headphoneInterface.requestGestureHoldToggledAncModes);
    }
  }
}
