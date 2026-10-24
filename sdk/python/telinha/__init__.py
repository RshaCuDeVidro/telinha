"""telinha: bots pro telinha (https://rshacudevidro.github.io/telinha/).

    from telinha import Bot

    bot = Bot("telinha://sala.exemplo:7777#senha", "Dado")

    @bot.command(help="joga um dado")
    async def dado(ctx, lados: int = 6):
        await ctx.reply(f"🎲 {random.randint(1, lados)}")

    bot.run()
"""
from .audio import FFmpegMissing, Player
from .bot import Bot, Command, CommandError, Context
from .client import EVENTS, SDK_VERSION, Client, Denied
from .connection import ConnectError, IdentityMismatch, WrongPassword
from .embed import Button, Click, Embed, Field, Icon, Style
from .image import ChatImage, ImageError
from .image import encode as encode_image
from .invite import Address, BadInvite, Invite
from .models import ChannelInfo, FileInfo, Member, Message, Quote, Welcome
from .video import Screen, VideoInfo, VideoPlayer
from .wire import Deny, Notice, Reaction

__version__ = SDK_VERSION

__all__ = [
    "Bot", "Client", "Context", "Command", "CommandError", "Player", "FFmpegMissing", "Screen", "VideoPlayer", "VideoInfo",
    "Embed", "Field", "Button", "Click", "Icon", "Style", "ChatImage", "ImageError", "encode_image",
    "Invite", "Address", "BadInvite", "Member", "Message", "Quote", "FileInfo", "ChannelInfo", "Welcome",
    "Denied", "ConnectError", "WrongPassword", "IdentityMismatch", "Deny", "Notice", "Reaction", "EVENTS",
]
