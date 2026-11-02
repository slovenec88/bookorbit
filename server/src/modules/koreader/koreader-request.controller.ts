import { Body, Controller, Delete, Get, Header, HttpCode, HttpStatus, Param, ParseIntPipe, Post, Query, UseGuards } from '@nestjs/common';
import { AuditAction, AuditResource } from '@bookorbit/types';

import { Auditable } from '../../common/decorators/auditable.decorator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Public } from '../../common/decorators/public.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { BookRequestService } from '../book-request/book-request.service';
import { CreateBookRequestDto } from '../book-request/dto/create-book-request.dto';
import { CreateBookRequestPairDto } from '../book-request/dto/create-book-request-pair.dto';
import { ListBookRequestsDto } from '../book-request/dto/list-book-requests.dto';
import { KoreaderAuthGuard } from './koreader-auth.guard';
import { KoreaderRequestGuard } from './koreader-request.guard';

@Public()
@UseGuards(KoreaderAuthGuard, KoreaderRequestGuard)
@Controller('koreader/plugin/requests')
export class KoreaderRequestController {
  constructor(private readonly requests: BookRequestService) {}

  @Get('access')
  @Header('Cache-Control', 'no-store')
  async access(@CurrentUser() user: RequestUser) {
    return {
      userId: user.id,
      libraries: await this.requests.getRequesterLibraries(user),
      canManageRequests: this.requests.canManageAll(user),
      canSelfFulfil: this.requests.canSelfFulfil(user),
    };
  }

  @Post()
  @Auditable({
    action: AuditAction.BookRequestCreate,
    resource: AuditResource.BookRequest,
    getResourceId: (_req, body) => (body as { request?: { id?: number } })?.request?.id,
    description: 'Created a book request from KOReader',
  })
  submit(@Body() dto: CreateBookRequestDto, @CurrentUser() user: RequestUser) {
    return this.requests.submit(dto, user);
  }

  @Post('pairs')
  @Auditable({
    action: AuditAction.BookRequestCreate,
    resource: AuditResource.BookRequest,
    getResourceId: (_req, body) => (body as { ebook?: { request?: { id?: number } } })?.ebook?.request?.id,
    description: 'Created ebook and audiobook requests from KOReader',
  })
  submitPair(@Body() dto: CreateBookRequestPairDto, @CurrentUser() user: RequestUser) {
    return this.requests.submitPair(dto, user);
  }

  @Get()
  @Header('Cache-Control', 'no-store')
  listMine(@Query() query: ListBookRequestsDto, @CurrentUser() user: RequestUser) {
    return this.requests.listMine(query, user);
  }

  @Get(':id')
  @Header('Cache-Control', 'no-store')
  getOne(@Param('id', ParseIntPipe) id: number, @CurrentUser() user: RequestUser) {
    return this.requests.getOne(id, user);
  }

  @Post(':id/cancel')
  @HttpCode(HttpStatus.OK)
  @Auditable({
    action: AuditAction.BookRequestCancel,
    resource: AuditResource.BookRequest,
    getResourceId: (req) => Number(req.params.id),
    description: 'Cancelled a book request from KOReader',
  })
  cancel(@Param('id', ParseIntPipe) id: number, @CurrentUser() user: RequestUser) {
    return this.requests.cancel(id, user);
  }

  @Delete(':id/subscription')
  @HttpCode(HttpStatus.NO_CONTENT)
  unsubscribe(@Param('id', ParseIntPipe) id: number, @CurrentUser() user: RequestUser) {
    return this.requests.unsubscribe(id, user);
  }
}
